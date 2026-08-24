#!/usr/bin/env bash
# Checks a configuration against the 16 GB ceiling on a machine with more RAM.
#
# macOS gives the GPU a share of physical memory (iogpu.wired_limit_mb,
# 0 = ~78% of RAM). By setting the limit by hand, a 32 GB machine gets the
# same conditions a 16 GB laptop would face: 16 GB * 0.78 ≈ 12.5 GB, minus
# headroom for the system -> 12800 MB (see mx.device_info() in CLAUDE.md:
# the real ceiling is 78% of RAM, not 75%).
#
# The script sets the limit, runs the given command, and ALWAYS restores
# the limit back to 0, even if the command is interrupted.
set -euo pipefail

LIMIT_MB="${LIMIT_MB:-12800}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $# -eq 0 ]]; then
    cat <<EOF
Usage: sudo ./check-16gb.sh <command> [args...]

Examples:
    sudo ./check-16gb.sh ./run-mlx.sh
    sudo LIMIT_MB=8000 ./check-16gb.sh ./run-mlx.sh --12b

Current limit: $(sysctl -n iogpu.wired_limit_mb) MB (0 = default, ~78% of RAM)
Physical memory: $(( $(sysctl -n hw.memsize) / 1024 / 1024 )) MB
EOF
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Needs sudo: iogpu.wired_limit_mb can only be written by root." >&2
    echo "Run: sudo $0 $*" >&2
    exit 1
fi

restore() {
    echo ""
    echo "Restoring iogpu.wired_limit_mb to 0 (default)..."
    sysctl -w iogpu.wired_limit_mb=0 >/dev/null
    echo "Done: $(sysctl -n iogpu.wired_limit_mb)"
}
trap restore EXIT INT TERM

echo "Setting GPU ceiling to $LIMIT_MB MB (emulating a 16 GB machine)..."
sysctl -w iogpu.wired_limit_mb="$LIMIT_MB"
echo ""

# Swap counters snapshot before the run: a rise in swapins/swapouts during
# the run means the configuration didn't fit under the limit.
before=$(vm_stat | awk '/Swapins|Swapouts/ {gsub(/\./,"",$NF); print $NF}' | paste -sd' ' -)

set +e
"$@"
rc=$?
set -e

after=$(vm_stat | awk '/Swapins|Swapouts/ {gsub(/\./,"",$NF); print $NF}' | paste -sd' ' -)

echo ""
echo "=== swapping during the run ==="
paste <(echo "$before" | tr ' ' '\n') <(echo "$after" | tr ' ' '\n') \
    | awk 'BEGIN{n["1"]="swapins";n["2"]="swapouts"}
           {printf "%-10s %s -> %s  (delta %d)\n", n[NR], $1, $2, $2-$1}'
echo ""
echo "A nonzero delta means the system paged memory out to disk: the"
echo "configuration didn't fit under $LIMIT_MB MB, even though the process didn't crash."

exit $rc
