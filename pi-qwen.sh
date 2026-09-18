#!/usr/bin/env bash
# Start the Rapid-MLX server if it isn't up, then open pi on Qwen3.8-27B.
# --tools keeps the system prompt short (faster prefill on a 27B local model).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
"$DIR/run-rapid-qwen.sh" --bg
exec pi --provider qwen38-rapid-mlx --model qwen3.8-27b --tools read,bash,edit,write "$@"
