#!/usr/bin/env bash
# Memory budget harness for ziki (spec 008).
#
# Launches N ziki instances and measures memory: idle steady-state or during
# active goal execution. Reports total + per-instance peak RSS. Asserts against
# budget (idle proxy: ~1.25 GB at 20 windows = 1/8 of the ~10 GB TS baseline).
#
# Usage: ./memory-harness.sh [mode] [N] [budget_kb]
#   mode        idle (steady-state REPL, default) or active-goal (execute goals)
#   N           number of instances (default 20)
#   budget_kb   total RSS budget in KB (default 1280000 ~ 1.25 GB)
#
# Exit 0 = within budget, 1 = breach or launch failure.

set -u

MODE="${1:-idle}"
N="${2:-20}"
BUDGET_KB="${3:-1280000}"
BIN="${ZIKI_BIN:-./zig-out/bin/ziki}"
SETTLE_S="${SETTLE_S:-2}"
GOAL_TIMEOUT_S="${GOAL_TIMEOUT_S:-30}"
SAMPLE_S="${SAMPLE_S:-20}"

if [[ ! -x "$BIN" ]]; then
  echo "error: ziki binary not found at '$BIN' (build with 'zig build')" >&2
  exit 1
fi

if [[ "$MODE" != "idle" && "$MODE" != "active-goal" ]]; then
  echo "error: mode must be 'idle' or 'active-goal'" >&2
  exit 1
fi

TMPDIR="$(mktemp -d)"
pids=()
fifo=""

cleanup() {
  if (( ${#pids[@]} > 0 )); then
    kill -KILL "${pids[@]}" 2>/dev/null
    wait "${pids[@]}" 2>/dev/null || true
  fi
  if [[ -n "$fifo" && -e "$fifo" ]]; then
    rm -f "$fifo" 2>/dev/null || true
  fi
  rm -rf "$TMPDIR" 2>/dev/null || true
}
trap cleanup EXIT

if [[ "$MODE" == "idle" ]]; then
  # Idle mode: FIFO held open keeps windows blocked reading stdin at steady state.
  fifo="$(mktemp -u)"
  mkfifo "$fifo"
  exec 3<>"$fifo"

  echo "launching $N idle ziki instances from $BIN ..."
  for ((i = 0; i < N; i++)); do
    "$BIN" < "$fifo" >/dev/null 2>&1 &
    pids+=($!)
  done

  # Let memory settle (allocator bookkeeping, first load, etc.).
  sleep "$SETTLE_S"

  # Sample steady-state RSS.
  declare -A peak
  for pid in "${pids[@]}"; do peak[$pid]=0; done
  for ((s = 0; s < SAMPLE_S; s += 1)); do
    for pid in "${pids[@]}"; do
      rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
      if [[ -n "$rss" && "$rss" -gt "${peak[$pid]}" ]]; then
        peak[$pid]="$rss"
      fi
    done
    sleep 1
  done
else
  # Active-goal mode: launch windows, sample peak RSS while they run, then
  # wait for completion. The sampler must run concurrently — goals finish
  # quickly and the process exits before a post-hoc poll would see it.
  echo "launching $N active-goal ziki instances from $BIN ..."
  declare -A peak
  for ((i = 0; i < N; i++)); do
    state_dir="$TMPDIR/state-$i"
    mkdir -p "$state_dir"

    input_fifo="$TMPDIR/input-$i"
    mkfifo "$input_fifo"

    {
      echo "/goal Write test-$i.txt with value-$i. --criterion test-$i.txt exists --timeout $GOAL_TIMEOUT_S"
      sleep $((GOAL_TIMEOUT_S + 5))
    } > "$input_fifo" &

    HOME="$state_dir" "$BIN" < "$input_fifo" >"$state_dir/stdout.log" 2>&1 &
    pid=$!
    pids+=($pid)
    peak[$pid]=0
  done

  for ((s = 0; s < SAMPLE_S; s += 1)); do
    for pid in "${pids[@]}"; do
      rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
      if [[ -n "$rss" && "$rss" -gt "${peak[$pid]}" ]]; then
        peak[$pid]="$rss"
      fi
    done
    sleep 1
  done

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
fi

total_kb=0
for pid in "${pids[@]}"; do
  if (( peak[$pid] == 0 )); then
    echo "error: window pid $pid produced no RSS sample" >&2
    exit 1
  fi
  total_kb=$((total_kb + peak[$pid]))
done

per_window_kb=$((total_kb / N))

echo ""
echo "mode:           $MODE"
echo "instances:      $N"
echo "total peak RSS: ${total_kb} KB ($((total_kb / 1024)) MB)"
echo "per-instance:   ${per_window_kb} KB ($((per_window_kb / 1024)) MB)"
echo "budget (total): ${BUDGET_KB} KB ($((BUDGET_KB / 1024)) MB)"
echo ""

if (( total_kb <= BUDGET_KB )); then
  echo "RESULT: PASS — within budget"
  exit 0
else
  echo "RESULT: FAIL — exceeded budget by $((total_kb - BUDGET_KB)) KB"
  exit 1
fi