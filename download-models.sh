#!/usr/bin/env bash
# Downloads the model weights this project needs. Run once on a fresh
# machine before ./run-mlx.sh or ./run.sh.
#
# MLX weights are plain mirrors of their mlx-community HF repos. The GGUF
# files are quantized releases from their original publishers: Google's
# own QAT release for the base model, Unsloth's MTP/ folder for the
# speculative-decoding sidecar (see "Why MLX, not llama.cpp" in CLAUDE.md
# for why the MTP sidecar doesn't actually help on Apple Silicon — it's
# only useful if you also want to reproduce that finding).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

WITH_E4B=1
WITH_12B=0
WITH_GGUF=0

usage() {
    cat <<'EOF'
Usage: ./download-models.sh [options]

    --12b       also download the 12B MLX weights (~6.3 GB)
    --no-e4b    skip the E4B MLX weights (downloaded by default, ~6.8 GB)
    --gguf      also download the GGUF weights for the llama.cpp path
                (base Q4_0 quant ~6.5 GB + MTP assistant sidecar ~450 MB)
    --all       shorthand for --12b --gguf

Weights land under models/, matching what run-mlx.sh / run.sh expect:
    models/mlx-e4b-qat-4bit/   <- mlx-community/gemma-4-E4B-it-qat-4bit
    models/mlx-4bit/           <- mlx-community/gemma-4-12B-it-4bit
    models/gguf/*.gguf         <- google/gemma-4-12B-it-qat-q4_0-gguf
                                   unsloth/gemma-4-12B-it-qat-GGUF (MTP/)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --12b)     WITH_12B=1; shift ;;
        --no-e4b)  WITH_E4B=0; shift ;;
        --gguf)    WITH_GGUF=1; shift ;;
        --all)     WITH_12B=1; WITH_GGUF=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# Homebrew's Python refuses global "pip install" (PEP 668,
# externally-managed-environment) — a venv is the straightforward fix, and
# .venv-mlx is the same one run-mlx.sh/update-deps.sh use, so this doesn't
# create a second, redundant environment.
if [[ -x .venv-mlx/bin/hf ]]; then
    HF=.venv-mlx/bin/hf
elif command -v hf >/dev/null 2>&1; then
    HF=hf
elif command -v huggingface-cli >/dev/null 2>&1; then
    HF=huggingface-cli
else
    echo "No huggingface_hub CLI found — setting one up in .venv-mlx..." >&2
    [[ -x .venv-mlx/bin/python ]] || python3 -m venv .venv-mlx
    .venv-mlx/bin/pip install -q -U pip "huggingface_hub[cli]"
    HF=.venv-mlx/bin/hf
fi

echo "Using: $HF"
echo ""

if [[ $WITH_E4B -eq 1 ]]; then
    echo "=== MLX E4B (~6.8 GB) ==="
    "$HF" download mlx-community/gemma-4-E4B-it-qat-4bit --local-dir models/mlx-e4b-qat-4bit
    echo ""
fi

if [[ $WITH_12B -eq 1 ]]; then
    echo "=== MLX 12B (~6.3 GB) ==="
    "$HF" download mlx-community/gemma-4-12B-it-4bit --local-dir models/mlx-4bit
    echo ""
fi

if [[ $WITH_GGUF -eq 1 ]]; then
    mkdir -p models/gguf

    echo "=== GGUF 12B QAT Q4_0 (~6.5 GB) ==="
    "$HF" download google/gemma-4-12B-it-qat-q4_0-gguf gemma-4-12b-it-qat-q4_0.gguf \
        --local-dir models/gguf

    echo "=== GGUF MTP assistant sidecar (~450 MB) ==="
    "$HF" download unsloth/gemma-4-12B-it-qat-GGUF MTP/mtp-gemma-4-12B-it-Q8_0.gguf \
        --local-dir models/gguf
    # Unsloth ships it under MTP/ — flatten to match the naming used
    # elsewhere in this repo (no subfolder, lowercase "12b").
    if [[ -f models/gguf/MTP/mtp-gemma-4-12B-it-Q8_0.gguf ]]; then
        mv models/gguf/MTP/mtp-gemma-4-12B-it-Q8_0.gguf models/gguf/mtp-gemma-4-12b-it-Q8_0.gguf
        rmdir models/gguf/MTP 2>/dev/null || true
    fi
    echo ""
fi

echo "Done. run-mlx.sh symlinks whichever MLX model you pass it on first launch."
