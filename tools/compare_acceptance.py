#!/usr/bin/env python3
"""Acceptance test: Local Nutrition (research protocol, none condition) vs the research batch application.

Both applications must be run on the same device with the same model folder. The app writes the exact
JPEG it gave to the model into Documents/model_inputs/; those files are copied into the batch application's
Documents/images/appcheck/ and run there under the "none" condition. This script pairs the two outputs by
file name and reports agreement.

--app accepts the app's analysis-log.jsonl or a batch export JSON (BatchExports/*.json).

Usage:
  python3 compare_acceptance.py --app analysis-log.jsonl \
      --ref appcheck_Qwen3-VL-4B-Instruct-4bit_L0.jsonl [--weights-sha shasum.txt] [--out result.csv]

  --weights-sha : output of `shasum -a 256 *.safetensors` for the model folder copied to the device
                  (optional; compared with the hashes the app recorded).
Exit status 0 when every paired image gives an identical raw response, 1 otherwise.
"""
import argparse, csv, json, os, re, sys

BASE = ("Look at this food image. Estimate the nutritional content based solely on visual "
        "appearance\u2014color, shape, ingredients, and portion size. Do NOT read any text, labels, "
        "or numbers visible in the image. Use only visual information. Provide a brief one-line "
        "explanation of your reasoning. Respond ONLY in JSON format: {energy_kcal: value, "
        "protein_g: value, fat_g: value, carb_g: value, salt_g: value, basis: one-line reasoning}")
FIELDS = ["energy_kcal", "protein_g", "fat_g", "carb_g", "salt_g"]
NUM = r"-?\d+(?:\.\d+)?"


def _numbers(obj):
    out = {}
    for f in FIELDS:
        v = obj.get(f)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            out[f] = float(v)
        elif isinstance(v, str):
            m = re.search(NUM, v)
            if m:
                out[f] = float(m.group())
    return out


def parse(raw):
    """Three stages as in the app (json -> quoted keys -> regex). Returns (energy or None, stage)."""
    t = raw.strip()
    t = re.sub(r"^```(?:json)?\s*", "", t)
    t = re.sub(r"\s*```$", "", t)
    try:
        o = json.loads(t)
        if isinstance(o, dict) and "energy_kcal" in _numbers(o):
            return _numbers(o)["energy_kcal"], "json"
    except ValueError:
        pass
    a, b = t.find("{"), t.rfind("}")
    if a != -1 and b > a:
        q = re.sub(r"([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*:)", r'\1"\2"\3', t[a:b + 1])
        try:
            o = json.loads(q)
            if isinstance(o, dict) and "energy_kcal" in _numbers(o):
                return _numbers(o)["energy_kcal"], "rescued_keys"
        except ValueError:
            pass
    m = re.search(r"energy_kcal\D*?(" + NUM + ")", t)
    if m:
        return float(m.group(1)), "rescued_regex"
    return None, "fail"


def read_jsonl(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        for i, line in enumerate(fh, 1):
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    print(f"warning: {path}:{i} is not JSON, skipped", file=sys.stderr)
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app", required=True)
    ap.add_argument("--ref", required=True)
    ap.add_argument("--weights-sha")
    ap.add_argument("--out", default="acceptance_result.csv")
    a = ap.parse_args()

    app = {}
    skipped = {"not_research": 0, "not_none": 0, "no_input": 0, "not_analysed": 0}
    if a.app.endswith(".json"):
        with open(a.app, encoding="utf-8") as fh:
            batch = json.load(fh)
        app_rows = batch.get("items", []) if isinstance(batch, dict) else batch
    else:
        app_rows = read_jsonl(a.app)
    for r in app_rows:
        if r.get("analysisMode") != "research_protocol":
            skipped["not_research"] += 1; continue
        if r.get("condition") not in (None, "none") or r.get("prompt") != BASE:
            skipped["not_none"] += 1; continue
        if not r.get("modelInputFilename"):
            skipped["no_input"] += 1; continue
        if r.get("status") != "解析済み" and not r.get("rawResponse"):
            skipped["not_analysed"] += 1; continue
        app[os.path.basename(r["modelInputFilename"])] = r

    ref = {}
    for r in read_jsonl(a.ref):
        if r.get("cond") == "none" and not r.get("error"):
            ref[r["image"]] = r

    keys = sorted(set(app) & set(ref))
    rows, raw_same, kcal_same, diffs = [], 0, 0, []
    for k in keys:
        ra, rr = app[k].get("rawResponse", ""), ref[k].get("raw", "")
        ea, sa = parse(ra)
        er, sr = parse(rr)
        same_raw = ra == rr
        same_kcal = ea is not None and er is not None and ea == er
        raw_same += same_raw; kcal_same += same_kcal
        if ea is not None and er is not None:
            diffs.append(ea - er)
        rows.append({"image": k, "raw_identical": int(same_raw), "kcal_identical": int(same_kcal),
                     "kcal_app": ea, "kcal_ref": er, "stage_app": sa, "stage_ref": sr,
                     "gen_sec_app": app[k].get("generationSeconds"), "sec_ref": ref[k].get("sec"),
                     "model_app": app[k].get("modelID"), "model_ref": ref[k].get("model"),
                     "device_app": app[k].get("deviceModel"), "device_ref": ref[k].get("device")})

    with open(a.out, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()) if rows else ["image"])
        w.writeheader(); w.writerows(rows)

    n = len(keys)
    print(f"app research/none rows: {len(app)}  (skipped: {skipped})")
    print(f"reference none rows   : {len(ref)}")
    print(f"paired by file name   : {n}")
    for name, only in (("app only", set(app) - set(ref)), ("reference only", set(ref) - set(app))):
        if only:
            print(f"  {name}: {len(only)} e.g. {sorted(only)[:3]}")
    if n:
        print(f"raw response identical: {raw_same}/{n} ({100 * raw_same / n:.1f}%)")
        print(f"energy identical      : {kcal_same}/{n} ({100 * kcal_same / n:.1f}%)")
        if diffs:
            print(f"mean energy difference (app - ref): {sum(diffs) / len(diffs):+.2f} kcal")
        for r in rows:
            if not r["raw_identical"]:
                print(f"  differs: {r['image']}  app={r['kcal_app']}  ref={r['kcal_ref']}")

    if a.weights_sha:
        expected = {}
        with open(a.weights_sha) as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 2:
                    expected[os.path.basename(parts[-1])] = parts[0].lower()
        recorded = {r.get("modelWeightsSHA256") for r in app.values()} - {None}
        for rec in sorted(recorded):
            got = dict(p.split("=", 1) for p in rec.split(";") if "=" in p)
            ok = got == expected
            print(f"weights hash {'matches' if ok else 'DOES NOT match'} --weights-sha ({len(got)} files)")
        if not recorded:
            print("weights hash: not recorded by the app (older version?)")

    print(f"table written to {a.out}")
    sys.exit(0 if n and raw_same == n else 1)


if __name__ == "__main__":
    main()
