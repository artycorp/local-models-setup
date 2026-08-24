#!/usr/bin/env bash
# Keeps llama.cpp and the MLX toolchain current. Safe to run repeatedly:
# clones/creates whatever is missing, otherwise just checks for updates
# and applies them.
#
# llama.cpp is a vendored upstream clone (see "Working with the
# llama.cpp/ directory" in CLAUDE.md) — updating it means git pull +
# rebuild, not a package manager. MLX is a handful of pip packages inside
# .venv-mlx; "latest" there just means pip install -U.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

WITH_LLAMACPP=1
WITH_MLX=1
REBUILD=1
USE_BREW=0

usage() {
    cat <<'EOF'
Usage: ./update-deps.sh [options]

    --no-llama-cpp   skip llama.cpp
    --no-mlx         skip the MLX venv (create/pip install -U)
    --no-rebuild     pull llama.cpp updates but don't rebuild (source path only)
    --brew           get llama.cpp via `brew install --HEAD` instead of the
                     vendored source build. Simpler, but Homebrew's Metal/BLAS
                     flags come from its separate "ggml" dependency, not the
                     -DGGML_METAL=ON -DGGML_BLAS=ON build this repo measured —
                     re-check prefill speed after switching to this path.

Clones llama.cpp and creates .venv-mlx if they don't exist yet, so this
also works as first-time setup on a fresh machine.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-llama-cpp) WITH_LLAMACPP=0; shift ;;
        --no-mlx)       WITH_MLX=0; shift ;;
        --no-rebuild)   REBUILD=0; shift ;;
        --brew)         USE_BREW=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

update_llama_cpp() {
    if [[ ! -d llama.cpp/.git ]]; then
        echo "=== llama.cpp: not found, cloning ggml-org/llama.cpp ==="
        git clone https://github.com/ggml-org/llama.cpp.git
    fi

    echo "=== llama.cpp: checking for updates ==="
    git -C llama.cpp fetch --quiet origin master
    local_rev=$(git -C llama.cpp rev-parse HEAD)
    remote_rev=$(git -C llama.cpp rev-parse origin/master)

    if [[ "$local_rev" == "$remote_rev" ]]; then
        echo "Already up to date: $(git -C llama.cpp log -1 --oneline)"
        return
    fi

    if [[ -n "$(git -C llama.cpp status --porcelain)" ]]; then
        echo "llama.cpp has local changes — not pulling automatically." >&2
        echo "Resolve manually: cd llama.cpp && git status" >&2
        return 1
    fi

    echo "Updating: $(git -C llama.cpp rev-parse --short HEAD) -> $(git -C llama.cpp rev-parse --short origin/master)"
    git -C llama.cpp checkout --quiet master
    git -C llama.cpp merge --ff-only origin/master

    if [[ $REBUILD -eq 1 ]]; then
        echo "=== llama.cpp: rebuilding (Metal + BLAS, Release) ==="
        cmake -B llama.cpp/build -S llama.cpp -DCMAKE_BUILD_TYPE=Release \
            -DGGML_METAL=ON -DGGML_BLAS=ON
        cmake --build llama.cpp/build -j
    fi
}

update_llama_cpp_brew() {
    if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew not found — install it first: https://brew.sh" >&2
        return 1
    fi

    echo "=== llama.cpp: updating via brew --HEAD ==="
    echo "Note: this build's Metal/BLAS tuning comes from brew's 'ggml'"
    echo "formula, not the flags this repo's benchmarks were measured with."
    # --fetch-HEAD forces brew to check origin/master even when a HEAD
    # install already exists; without it, brew treats any HEAD install
    # as current and never looks for new commits.
    brew install --HEAD --fetch-HEAD llama.cpp
}

update_mlx() {
    if [[ ! -x .venv-mlx/bin/python ]]; then
        echo "=== MLX venv: not found, creating .venv-mlx ==="
        python3 -m venv .venv-mlx
        .venv-mlx/bin/pip install -q -U pip
    fi

    echo "=== MLX: checking for updates ==="
    before=$(.venv-mlx/bin/pip show mlx-vlm 2>/dev/null | awk '/^Version/{print $2}')
    .venv-mlx/bin/pip install -q -U mlx-vlm "huggingface_hub[cli]"
    after=$(.venv-mlx/bin/pip show mlx-vlm 2>/dev/null | awk '/^Version/{print $2}')

    if [[ "$before" == "$after" ]]; then
        echo "mlx-vlm already at latest ($after)"
    else
        echo "mlx-vlm: ${before:-not installed} -> $after"
    fi
}

if [[ $WITH_LLAMACPP -eq 1 ]]; then
    if [[ $USE_BREW -eq 1 ]]; then
        update_llama_cpp_brew
    else
        update_llama_cpp
    fi
fi
[[ $WITH_MLX -eq 1 ]] && update_mlx

echo ""
echo "Done."
