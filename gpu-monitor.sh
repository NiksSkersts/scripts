#!/usr/bin/env bash
set -euo pipefail

# Log NVIDIA GPU temperature, clocks, power and throttle reasons to CSV.
# Optionally wraps a command (e.g. bench-ollama.sh) and monitors for its duration.

GPU=0
INTERVAL=1
DURATION=0
AFTER=0
OUTPUT=""
LOAD_UTIL=50
LIVE=auto

usage() {
  cat <<'HELP'
Usage:
  bash gpu-monitor.sh [options]                 Monitor until Ctrl+C or --duration
  bash gpu-monitor.sh [options] -- COMMAND...   Monitor while COMMAND runs

Options:
  --gpu N            GPU index (default: 0)
  --interval SEC     Sample interval in seconds, decimals allowed (default: 1)
  --duration SEC     Stop after SEC seconds; 0 = until Ctrl+C (default: 0)
                     Ignored when a COMMAND is given.
  --after SEC        Keep monitoring SEC seconds after COMMAND ends,
                     to see the cool-down (default: 0)
  --output PATH      CSV file; must not already exist
                     (default: gpu-monitor-YYYYmmdd-HHMMSS.csv)
  --load-util PCT    GPU utilisation at or above which a sample counts as
                     "under load" in the summary (default: 50)
  --live true|false  Print one line per sample (default: true without a
                     COMMAND, false with one so its output stays readable)
  --help             Show help

Both --option value and --option=value are supported.

Examples:
  # Watch the card live until Ctrl+C
  bash gpu-monitor.sh

  # Monitor a benchmark, keep logging 30 s afterwards
  bash gpu-monitor.sh --output dgpu-max-monitor.csv --after 30 -- \
    bash bench-ollama.sh --model qwen3.5:4b --prompt-file max-prompt.txt \
      --runs 5 --label dGPU-GTX1080Ti-max --context 8192 --tokens 1024 \
      --threads 6 --gpu-layers 999 --output dgpu-max-results.jsonl
HELP
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

is_number() {
  [[ "$1" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]]
}

# ---- Arguments --------------------------------------------------------------

COMMAND=()
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --) shift; COMMAND=("$@"); break ;;
    --*=*) option="${1%%=*}"; value="${1#*=}"; shift ;;
    --*)
      option="$1"
      (($# >= 2)) || fail "$option requires a value"
      [[ "$2" != --* ]] || fail "$option requires a value"
      value="$2"; shift 2
      ;;
    *) fail "Unexpected argument: $1. Use --help." ;;
  esac

  case "$option" in
    --gpu)
      [[ "$value" =~ ^[0-9]+$ ]] || fail "--gpu requires a nonnegative integer"
      GPU="$value" ;;
    --interval)
      is_number "$value" && awk -v v="$value" 'BEGIN{exit !(v >= 0.1)}' ||
        fail "--interval requires a number of at least 0.1"
      INTERVAL="$value" ;;
    --duration|--after)
      is_number "$value" || fail "$option requires a nonnegative number"
      [[ "$option" == --duration ]] && DURATION="$value" || AFTER="$value" ;;
    --output) OUTPUT="$value" ;;
    --load-util)
      [[ "$value" =~ ^[0-9]+$ ]] && ((value <= 100)) ||
        fail "--load-util requires an integer from 0 to 100"
      LOAD_UTIL="$value" ;;
    --live)
      [[ "$value" == true || "$value" == false ]] ||
        fail "--live must be true or false"
      LIVE="$value" ;;
    *) fail "Unknown option: $option" ;;
  esac
done

if [[ "$LIVE" == auto ]]; then
  ((${#COMMAND[@]})) && LIVE=false || LIVE=true
fi

[[ -n "$OUTPUT" ]] || OUTPUT="gpu-monitor-$(date +%Y%m%d-%H%M%S).csv"

command -v nvidia-smi >/dev/null 2>&1 || fail "nvidia-smi not found"

# ---- Query fields -------------------------------------------------------------

# Newer drivers call these clocks_event_reasons; older ones clocks_throttle_reasons.
if nvidia-smi -i "$GPU" --query-gpu=clocks_event_reasons.active \
     --format=csv,noheader >/dev/null 2>&1; then
  R=clocks_event_reasons
else
  R=clocks_throttle_reasons
fi

FIELDS=(
  timestamp
  temperature.gpu
  clocks.sm
  clocks.mem
  clocks.max.sm
  power.draw
  power.limit
  utilization.gpu
  utilization.memory
  fan.speed
  pstate
  memory.used
  "$R.gpu_idle"
  "$R.sw_power_cap"
  "$R.sw_thermal_slowdown"
  "$R.hw_slowdown"
  "$R.hw_thermal_slowdown"
  "$R.hw_power_brake_slowdown"
)
HEADER="timestamp, temp_c, sm_mhz, mem_mhz, sm_max_mhz, power_w, power_limit_w, util_gpu_pct, util_mem_pct, fan_pct, pstate, mem_used_mib, idle, sw_power_cap, sw_thermal, hw_slowdown, hw_thermal, hw_power_brake"

QUERY="$(IFS=,; printf '%s' "${FIELDS[*]}")"

GPU_NAME="$(nvidia-smi -i "$GPU" --query-gpu=name,driver_version \
  --format=csv,noheader 2>/dev/null)" ||
  fail "Cannot query GPU $GPU. Check the index with: nvidia-smi -L"

nvidia-smi -i "$GPU" --query-gpu="$QUERY" --format=csv,noheader,nounits \
  >/dev/null 2>&1 ||
  fail "This driver rejects one of the query fields. Run: nvidia-smi --help-query-gpu"

if ! (set -o noclobber; printf '%s\n' "$HEADER" > "$OUTPUT") 2>/dev/null; then
  fail "Cannot create output file (does it already exist?): $OUTPUT"
fi

INTERVAL_MS="$(awk -v s="$INTERVAL" 'BEGIN{printf "%d", s * 1000}')"

# ---- Live display and summary --------------------------------------------------

live_line() {
  awk -F', ' '
    function flag(v, name) { return (v == "Active") ? name " " : "" }
    {
      t = flag($14, "power-cap") flag($15, "sw-thermal") flag($16, "hw-slowdown") \
          flag($17, "hw-thermal") flag($18, "power-brake")
      sub(/ $/, "", t)
      if (t == "") t = ($13 == "Active") ? "idle" : "none"
      split($1, ts, " ")
      printf "%s  %3s°C  SM %5s/%s MHz  Mem %5s MHz  %6s/%s W  GPU %3s%%  Fan %3s%%  %s  limits: %s\n",
        substr(ts[2], 1, 8), $2, $3, $5, $4, $6, $7, $8, $10, $11, t
      fflush()
    }' >&2
}

summary() {
  awk -F', ' -v load="$LOAD_UTIL" -v gpu="$GPU_NAME" -v file="$OUTPUT" '
    function num(x) { return x ~ /^-?[0-9]+([.][0-9]+)?$/ }
    function add(k, v) {
      if (!num(v)) return
      v += 0; n[k]++; s[k] += v
      if (!(k in lo) || v < lo[k]) lo[k] = v
      if (!(k in hi) || v > hi[k]) hi[k] = v
    }
    function avg(k) { return n[k] ? s[k] / n[k] : 0 }
    function row(label, k, unit) {
      if (n[k]) printf "  %-16s min %7.1f   avg %7.1f   max %7.1f %s\n", label, lo[k], avg(k), hi[k], unit
      else      printf "  %-16s n/a\n", label
    }
    function part(arr, from, to,   i, sum, c) {
      for (i = from; i <= to; i++) if (num(arr[i])) { sum += arr[i]; c++ }
      return c ? sum / c : 0
    }
    NR == 1 { next }
    {
      total++
      if (first == "") first = $1
      last = $1
      add("peak_temp", $2)
      if (num($5)) smmax = $5
      if (num($7)) plim = $7
      if (num($8) && $8 + 0 >= load) {
        L++
        add("temp", $2); add("sm", $3); add("mem", $4); add("pwr", $6)
        add("util", $8); add("fan", $10)
        smv[L] = $3; tv[L] = $2
        for (i = 14; i <= 18; i++) if ($i == "Active") act[i]++
      }
    }
    END {
      printf "\n=== GPU monitor summary ===\n"
      printf "GPU:      %s\n", gpu
      printf "Log:      %s\n", file
      printf "Period:   %s -> %s\n", first, last
      printf "Samples:  %d total, %d under load (GPU utilisation >= %d%%)\n", total, L, load
      if (n["peak_temp"]) printf "Peak temperature over the whole log: %d°C\n", hi["peak_temp"]
      if (!L) { print "\nNo samples under load, so no load statistics."; exit }

      printf "\nUnder load:\n"
      row("Temperature", "temp", "°C")
      row("SM clock", "sm", "MHz" (smmax ? "  (max supported " smmax " MHz)" : ""))
      row("Memory clock", "mem", "MHz")
      row("Power draw", "pwr", "W" (plim ? "  (limit " plim " W)" : ""))
      row("GPU utilisation", "util", "%")
      row("Fan", "fan", "%")

      k = int(L / 10); if (k < 1) k = 1
      if (L >= 4) {
        a = part(smv, 1, k); b = part(smv, L - k + 1, L)
        ta = part(tv, 1, k); tb = part(tv, L - k + 1, L)
        printf "\nTrend, first 10%% vs last 10%% of loaded samples:\n"
        printf "  SM clock         %.0f -> %.0f MHz (%+.1f%%)\n", a, b, a ? (b - a) / a * 100 : 0
        printf "  Temperature      %.0f -> %.0f °C\n", ta, tb
      }

      split("sw_power_cap sw_thermal hw_slowdown hw_thermal hw_power_brake", names, " ")
      printf "\nClock limits active (share of loaded samples):\n"
      for (i = 14; i <= 18; i++)
        printf "  %-16s %5.1f%%\n", names[i - 13], 100 * act[i] / L

      if (act[15] || act[17])      v = "Thermal throttling detected: the card is slowing down because of temperature."
      else if (act[16] || act[18]) v = "Hardware slowdown detected (power brake or hardware signal)."
      else if (act[14] / L > 0.5)  v = "Mostly limited by the power limit. Normal for a card under full load."
      else                          v = "No significant throttling detected."
      printf "\nVerdict:  %s\n", v
    }' "$OUTPUT" >&2
}

# ---- Run ----------------------------------------------------------------------

NSMI_PID=""
LIVE_PID=""
CMD_STATUS=0
FINISHED=false

finish() {
  $FINISHED && return
  FINISHED=true
  trap - INT TERM
  if [[ -n "$NSMI_PID" ]]; then
    kill "$NSMI_PID" 2>/dev/null || true
    wait "$NSMI_PID" 2>/dev/null || true
  fi
  if [[ -n "$LIVE_PID" ]]; then
    wait "$LIVE_PID" 2>/dev/null || true
  fi
  summary
}
trap finish EXIT
trap 'exit 130' INT TERM

printf 'Monitoring GPU %s: %s\n' "$GPU" "$GPU_NAME" >&2
printf 'Sampling every %ss -> %s\n' "$INTERVAL" "$OUTPUT" >&2

BUFFER=()
command -v stdbuf >/dev/null 2>&1 && BUFFER=(stdbuf -oL)

"${BUFFER[@]}" nvidia-smi -i "$GPU" --query-gpu="$QUERY" \
  --format=csv,noheader,nounits -lms "$INTERVAL_MS" >> "$OUTPUT" &
NSMI_PID=$!

if [[ "$LIVE" == true ]]; then
  tail -n +2 -f --pid="$NSMI_PID" -- "$OUTPUT" 2>/dev/null | live_line &
  LIVE_PID=$!
fi

if ((${#COMMAND[@]})); then
  printf 'Running: %s\n\n' "${COMMAND[*]}" >&2
  "${COMMAND[@]}" || CMD_STATUS=$?
  if awk -v a="$AFTER" 'BEGIN{exit !(a > 0)}'; then
    printf '\nCommand finished (exit %s). Monitoring %ss of cool-down...\n' \
      "$CMD_STATUS" "$AFTER" >&2
    sleep "$AFTER" & wait $!
  fi
  # Let the last sample land.
  sleep "$INTERVAL" & wait $!
elif awk -v d="$DURATION" 'BEGIN{exit !(d > 0)}'; then
  printf 'Stopping after %ss (Ctrl+C to stop early).\n' "$DURATION" >&2
  sleep "$DURATION" & wait $!
else
  printf 'Press Ctrl+C to stop.\n' >&2
  wait "$NSMI_PID" || true
fi

exit "$CMD_STATUS"
