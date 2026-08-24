# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A personal setup for local Gemma inference on Apple Silicon: `llama.cpp` built from source (Metal backend) plus a thin Node proxy that captures generation stats into `~/.llm-stats`. The only code that's actually ours is two files — `run.sh` and `llm-proxy.mjs`; everything under `llama.cpp/` is an upstream clone.

There are two ways to run it: the old llama.cpp path (`run.sh`) and the newer MLX path (`run-mlx.sh`).
For long documents, MLX is the one that works — see "Why MLX, not llama.cpp" below.

## Process topology

```
run.sh     ──► llama-server        :8080   (GGUF, Metal)
run-mlx.sh ──► mlx_server_tuned.py :8080   (MLX, same OpenAI-compatible /v1)
           └─► llm-proxy.mjs       :8081 ──► 192.168.10.25:8081  (remote box)
                                             └─► writes ~/.llm-stats
```

An important mismatch that's easy to mistake for a bug: the proxy does **not** proxy the local server on :8080. `TARGET_HOST` in `llm-proxy.mjs:11` hardcodes the machine `192.168.10.25`, while `run.sh` starts its own server on :8080 and launches the proxy alongside it. So the proxy serves the remote instance, not the one that just started. Context sizes diverge the same way: `--ctx-size 131072` in `run.sh` versus `CTX_SIZE = 98304` in the proxy (that constant is only used to compute the fill percentage in the stats). Confirm with the user which of the two is meant to be authoritative before changing either.

The proxy only computes stats for URLs containing `/completions`; everything else is just piped through. Timings come from the last SSE chunk (`extractTimings`), so the response to the client isn't buffered — chunks are forwarded immediately while a copy accumulates for parsing.

## Why MLX, not llama.cpp

Measured on an M1 Pro on a 123K-token document (August 2026, llama.cpp build 1459):

| runtime | model | prefill | prefill time | peak memory |
|---|---|---|---|---|
| MLX | E4B, 80K context | 443 tok/s | 3.0 min | 11.69 GB |
| MLX | 12B, 123K | 83 tok/s | 25 min | 11.75 GB |
| llama.cpp | 12B, 123K | 27 tok/s (computed) | 76 min | ~10.2 GB |

The reason llama.cpp lags isn't the algorithm — it's one kernel. Both runtimes equally
bound the sliding-window layers (visible in llama.cpp as a 480 MiB KV buffer instead of
2048, and in mlx-vlm via `RotatingKVCache`). But Gemma 4's global attention layers are
MQA with one KV head per 16 Q heads, and llama.cpp's Metal kernel delivers
**0.51 TFLOPS versus the 3.82 TFLOPS** the same GPU gets on matrix multiplies. Flags
don't fix it; also confirmed that the MTP sidecar (`draft-mtp`) doesn't help — it
doesn't speed up decoding on M1 Pro at any depth.

The model `t = a·N + b·N²` describes llama.cpp with ≤0.1% error: `a = 5.71e-3` s/token,
`b = 2.55e-7` s/token². At 131K the quadratic term eats 85% of the time.

### What matters about E4B

"Effective 4B" means 4.5B parameters take part in matrix multiplies, but the model has
about 13B total: Per-Layer Embeddings take up 262144 × 42 × 256 ≈ 2.8B parameters, of
which one row per token is actually read. So E4B is **4.7x faster than 12B, but needs
0.5 GB more memory**, and on 16 GB holds about 80K context versus the full 128K on 12B.
The choice between them isn't "smaller/bigger" — it's "speed or window".

The GPU ceiling on macOS is 78% of RAM (`mx.device_info()["max_recommended_working_set_size"]`),
i.e. 12.5 GB on a 16 GB machine. To check a configuration against that ceiling:
`sudo ./check-16gb.sh ./run-mlx.sh` — the script sets `iogpu.wired_limit_mb`, runs the
command, shows the swapins/swapouts delta, and always restores the limit to 0.

Be careful with `mx.set_memory_limit`: it's a **recommendation**, not a hard cap —
exceeding it is allowed as long as there's RAM or swap available, so "stayed under the
limit" proves nothing on a machine with headroom.

### The `model` field in requests to the mlx-vlm server

The server doesn't support aliases: the `model` value must be a path to the weights,
and an unrecognized value makes it reach out to HuggingFace and return 401. That's why
`run-mlx.sh` keeps `gemma-e4b` and `gemma-12b` symlinks in the project root and starts
the server through them — the client sends the short name, the path matches what's
loaded, and the weights never get reloaded. Sending a different path to the same
weights makes the server reload the model (~30 seconds), but it won't duplicate it in
memory. `/v1/models` returns an empty list in the meantime.

## Commands

```bash
./update-deps.sh              # clones/updates llama.cpp + rebuilds, creates/updates .venv-mlx
./download-models.sh          # fetches E4B MLX weights (default); --12b / --gguf / --all for the rest
./run-mlx.sh                  # MLX + E4B (default), model: "gemma-e4b"
./run-mlx.sh --12b            # MLX + 12B, full 128K, model: "gemma-12b"
sudo ./check-16gb.sh ./run-mlx.sh   # check against the 16 GB machine's ceiling
./run.sh                      # llama-server + proxy, waits for /health, kills both on Ctrl-C
./start-proxy.sh              # proxy only (pid in /tmp/llm-proxy.pid)
./stop-proxy.sh
cat ~/.llm-stats              # context, speed, cache hits for the last request
curl -sf localhost:8080/health
```

`run.sh` expects the model at `models/google_gemma-4-26B-A4B-it-Q4_K_M.gguf` from the repo root. There's currently no `models/` directory in the working tree — the script will fail with a clear error until the GGUF is placed there.

## Building llama.cpp

A build already exists in `llama.cpp/build` (Unix Makefiles, `Release`, `GGML_METAL=ON`, `GGML_BLAS=ON`). `./update-deps.sh` handles the whole cycle — clone if missing, `git pull` if behind `origin/master`, rebuild with the same flags — and does the same for `.venv-mlx` (`pip install -U mlx-vlm`). To do it by hand instead:

```bash
cmake -B llama.cpp/build -S llama.cpp -DCMAKE_BUILD_TYPE=Release
cmake --build llama.cpp/build -j            # or --target llama-server if only the server is needed
```

Upstream tests:

```bash
ctest --test-dir llama.cpp/build             # all of them
ctest --test-dir llama.cpp/build -R tokenizer -V   # one, by name regex
```

## Working with the llama.cpp/ directory

`llama.cpp/` is a **separate git repository** (`origin` = `ggml-org/llama.cpp`, branch `master`), not a submodule of this one — it's gitignored here and versioned on its own. Treat it as a vendored dependency: changes made there mean drifting from upstream on the next `git pull`.

Upstream has its own agent instructions — `llama.cpp/AGENTS.md`. The key point: the project **does not accept PRs that are primarily AI-written**. If work turns into changing llama.cpp itself with an eye toward upstreaming it, read `llama.cpp/AGENTS.md` and `llama.cpp/CONTRIBUTING.md` in full first.
