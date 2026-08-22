#!/usr/bin/env bash
# Memory budget harness for ziki (spec 008).
#
# Launches N idle ziki REPL windows, lets them reach steady state, and reports
# total + per-window resident memory (RSS). Asserts the total against the budget
# (proxy: ~1.25 GB at 20 windows = 1/8 of the ~10 GB TypeScript baseline).
#
# Usage: ./memory-harness.sh [N] [budget_kb]
#   N           number of windows (default 20)
#   budget_kb   total RSS budget in KB (default 1280000 ~ 1.25 GB)
#
# Exit 0 = within budget, 1 = breach or launch failure.

set -u

N="${1:-20}"
BUDGET_KB="${2:-1280000}"
BIN="${ZIKI_BIN:-./zig-out/bin/ziki}"
SETTLE_S="${SETTLE_S:-2}"

if [[ ! -x "$BIN" ]]; then
  echo "error: ziki binary not found at '$BIN' (build with 'zig build')" >&2
  exit 1
fi

# A FIFO held open on the write end keeps every window blocked reading stdin
# (no EOF) so they remain alive at steady state until we kill them.
fifo="$(mktemp -u)"
mkfifo "$fifo"
exec 3<>"$fifo"

echo "launching $N idle ziki windows from $BIN ..."
pids=()
for ((i = 0; i < N; i++)); do
  # Redirect child stdout/stderr to /dev/null so they never hold our pipeline open.
  "$BIN" < "$fifo" >/dev/null 2>&1 &
  pids+=($!)
done

# Let memory settle (allocator bookkeeping, first load, etc.).
sleep "$SETTLE_S"

total_kb=0
for pid in "${pids[@]}"; do
  rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
  if [[ -z "$rss" ]]; then
    echo "error: window pid $pid is not running" >&2
    kill -KILL "${pids[@]}" 2>/dev/null
    exec 3>&-
    rm -f "$fifo"
    exit 1
  fi
  total_kb=$((total_kb + rss))
done

per_window_kb=$((total_kb / N))

echo "windows:        $N"
echo "total RSS:      ${total_kb} KB ($((total_kb / 1024)) MB)"
echo "per-window:     ${per_window_kb} KB ($((per_window_kb / 1024)) MB)"
echo "budget (total): ${BUDGET_KB} KB ($((BUDGET_KB / 1024)) MB)"

# Cleanup (force kill so a blocked reader cannot linger).
kill -KILL "${pids[@]}" 2>/dev/null
exec 3>&-
rm -f "$fifo"

if (( total_kb <= BUDGET_KB )); then
  echo "RESULT: PASS — within budget"
  exit 0
else
  echo "RESULT: FAIL — exceeded budget by $((total_kb - BUDGET_KB)) KB"
  exit 1
fi
