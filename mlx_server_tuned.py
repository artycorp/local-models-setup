"""Runs the mlx-vlm server with tuned MLX memory limits.

The server's CLI gives no control over the allocator, and on 16 GB that's
what decides whether a configuration fits or swaps. Two levers:

  cache_limit  — MLX keeps freed buffers in a cache to avoid hitting the
                 allocator for every tensor. Fine on a machine with headroom,
                 but on a tight one the cache inflates the peak by 1-1.5 GB.

  wired_limit  — how much memory stays resident. Zero (default) leaves it
                 up to the system; it can't be set above the system limit,
                 which only goes up via sudo sysctl iogpu.wired_limit_mb.

Both values come from environment variables so run-mlx.sh can change them
without touching this file.
"""

import os
import runpy
import sys

import mlx.core as mx


def _gb(name: str, default: str) -> float:
    raw = os.environ.get(name, default)
    try:
        return float(raw)
    except ValueError:
        print(f"[mlx-tuned] {name}={raw!r} is not a number, using {default}", file=sys.stderr)
        return float(default)


def main() -> None:
    cache_gb = _gb("MLX_CACHE_GB", "0.3")
    mx.set_cache_limit(int(cache_gb * 1e9))

    info = mx.device_info()
    recommended = info["max_recommended_working_set_size"] / 1e9
    total = info["memory_size"] / 1e9

    wired_gb = _gb("MLX_WIRED_GB", "0")
    if wired_gb > 0:
        if wired_gb >= recommended:
            print(
                f"[mlx-tuned] wired_limit {wired_gb:.1f} GB is not below the system "
                f"limit of {recommended:.1f} GB — skipping, otherwise MLX would raise an error",
                file=sys.stderr,
            )
        else:
            mx.set_wired_limit(int(wired_gb * 1e9))

    print(
        f"[mlx-tuned] RAM {total:.1f} GB, GPU ceiling {recommended:.1f} GB, "
        f"MLX cache {cache_gb:.1f} GB",
        flush=True,
    )

    sys.argv = ["mlx_vlm.server"] + sys.argv[1:]
    runpy.run_module("mlx_vlm.server", run_name="__main__")


if __name__ == "__main__":
    main()
