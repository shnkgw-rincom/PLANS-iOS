#!/bin/zsh
# Prepare a Qwen3-VL model folder for transfer to the device (Finder > device > Files > Local Nutrition).
# The weights are not part of this repository. Download them once on the Mac, e.g.
#   huggingface-cli download mlx-community/Qwen3-VL-4B-Instruct-4bit
# then run:  ./prepare-models.sh 4B   [destination-directory]
# The script copies the Hugging Face cache snapshot, and writes the snapshot revision and the
# SHA-256 of every *.safetensors file next to the folder (used by tools/compare_acceptance.py).
set -euo pipefail

if [[ $# -lt 1 || ( "$1" != "2B" && "$1" != "4B" && "$1" != "8B" ) ]]; then
  print -u2 "usage: ./prepare-models.sh 2B|4B|8B [destination-directory]"
  exit 2
fi

size="$1"
name="Qwen3-VL-${size}-Instruct-4bit"
cache="${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}/models--mlx-community--${name}/snapshots"
snapshots=("$cache"/*(N/))
if (( ${#snapshots} == 0 )); then
  print -u2 "model not found in the Hugging Face cache: $cache"
  exit 1
fi
if (( ${#snapshots} > 1 )); then
  print -u2 "several snapshots found; using the first. Remove old ones to be explicit:"
  print -u2 -l -- "${snapshots[@]}"
fi

source_dir="${snapshots[1]}"
revision="${source_dir:t}"
dest_root="${2:-${0:A:h:h}/ModelTransfer}"
destination="$dest_root/$name"
mkdir -p "$destination"
rsync -aL --delete "$source_dir/" "$destination/"
if [[ ! -f "$destination/config.json" || ! -f "$destination/tokenizer.json" ]]; then
  print -u2 "model files could not be prepared"
  exit 1
fi
print "mlx-community/${name} revision ${revision}" > "$dest_root/${name}.revision.txt"
( cd "$destination" && shasum -a 256 *.safetensors ) > "$dest_root/${name}.sha256.txt"
print "ready   : $destination"
print "revision: $revision"
print "sha256  : $dest_root/${name}.sha256.txt"
print "Transfer the folder with Finder (device > Files > Local Nutrition), then tap 'Re-check installed models'."
