"""Запуск сервера mlx-vlm с настроенными лимитами памяти MLX.

CLI сервера не даёт управлять аллокатором, а на 16 ГБ это решает, влезет
конфигурация или уйдёт в своп. Два рычага:

  cache_limit  — MLX держит освобождённые буферы в кэше, чтобы не ходить к
                 аллокатору за каждым тензором. На машине с запасом это
                 правильно, на тесной — кэш раздувает пик на 1-1.5 ГБ.

  wired_limit  — сколько памяти останется резидентной. Ноль (по умолчанию)
                 означает решение на усмотрение системы; задавать его выше
                 системного лимита нельзя, он поднимается только через
                 sudo sysctl iogpu.wired_limit_mb.

Обе величины задаются переменными окружения, чтобы run-mlx.sh мог их
менять, не трогая этот файл.
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
        print(f"[mlx-tuned] {name}={raw!r} — не число, беру {default}", file=sys.stderr)
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
                f"[mlx-tuned] wired_limit {wired_gb:.1f} ГБ не ниже системного "
                f"лимита {recommended:.1f} ГБ — пропускаю, иначе MLX выдаст ошибку",
                file=sys.stderr,
            )
        else:
            mx.set_wired_limit(int(wired_gb * 1e9))

    print(
        f"[mlx-tuned] RAM {total:.1f} ГБ, потолок GPU {recommended:.1f} ГБ, "
        f"кэш MLX {cache_gb:.1f} ГБ",
        flush=True,
    )

    sys.argv = ["mlx_vlm.server"] + sys.argv[1:]
    runpy.run_module("mlx_vlm.server", run_name="__main__")


if __name__ == "__main__":
    main()
