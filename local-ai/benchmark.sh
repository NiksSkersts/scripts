#!/usr/bin/env bash
set -euo pipefail

MODEL="qwen3.5:4b"
PROMPT="Explain how a refrigerator works in about 300 words."
PROMPT_FILE=""
RUNS=3
LABEL="unlabelled"
OUTPUT=""
OLLAMA_URL="http://127.0.0.1:11434"

CONTEXT=8192
TOKENS=400
TEMPERATURE=0
SEED=42
THINK=false
THREADS=""
GPU_LAYERS=""
COLD=true
KEEP_ALIVE="10m"
TIMEOUT=1800

usage() {
  cat <<'HELP'
Usage:
  bash bench-ollama.sh [options]

Options:
  --model NAME           Model (default: qwen3.5:4b)
  --prompt TEXT          Prompt text
  --prompt-file PATH     Read prompt from a file; overrides --prompt
  --runs N               Repetitions (default: 3)
  --label TEXT           Result label: CPU, iGPU, GTX1080Ti, etc.
  --output PATH          JSON Lines results file; must not already exist
  --url URL              Ollama URL (default: http://127.0.0.1:11434)

  --context N            Context size (default: 8192)
  --tokens N             Maximum generated tokens (default: 400)
  --temperature N        Sampling temperature (default: 0)
  --seed N               Random seed (default: 42)
  --think true|false     Thinking mode (default: false)
  --threads N            CPU threads (default: automatic)
  --gpu-layers N         GPU layers; 0 forces CPU (default: automatic)

  --cold true|false      Unload model before every run (default: true)
  --keep-alive VALUE     Keep model loaded afterward (default: 10m)
  --timeout N           Timeout per HTTP request in seconds (default: 1800)
  --help                Show help

Both --option value and --option=value are supported.

Cold mode unloads model memory, not Linux filesystem caches.
Warm mode performs one unmeasured warm-up before measured runs.
Labels do not select hardware. Verify placement with ollama ps.
Model must already be downloaded.
HELP
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

for command in curl jq; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Missing dependency: $command"
done

while (($#)); do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --*=*)
      option="${1%%=*}"
      value="${1#*=}"
      shift
      ;;
    --*)
      option="$1"
      (($# >= 2)) || fail "$option requires a value"
      [[ "$2" != --* ]] || fail "$option requires a value"
      value="$2"
      shift 2
      ;;
    *)
      fail "Unexpected argument: $1. Use --help."
      ;;
  esac

  case "$option" in
    --runs|--context|--tokens|--threads|--timeout)
      [[ "$value" =~ ^[1-9][0-9]*$ ]] ||
        fail "$option requires a positive integer"
      ;;
    --gpu-layers)
      [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] ||
        fail "$option requires a nonnegative integer"
      ;;
    --seed)
      [[ "$value" =~ ^-?(0|[1-9][0-9]*)$ ]] ||
        fail "$option requires an integer"
      ;;
    --temperature)
      jq -en --arg value "$value" \
        '$value | tonumber | . >= 0' >/dev/null 2>&1 ||
        fail "$option requires a nonnegative number"
      ;;
    --think|--cold)
      [[ "$value" == true || "$value" == false ]] ||
        fail "$option must be true or false"
      ;;
  esac

  case "$option" in
    --model)       MODEL="$value" ;;
    --prompt)      PROMPT="$value" ;;
    --prompt-file) PROMPT_FILE="$value" ;;
    --runs)        RUNS="$value" ;;
    --label)       LABEL="$value" ;;
    --output)      OUTPUT="$value" ;;
    --url)         OLLAMA_URL="$value" ;;
    --context)     CONTEXT="$value" ;;
    --tokens)      TOKENS="$value" ;;
    --temperature) TEMPERATURE="$value" ;;
    --seed)        SEED="$value" ;;
    --think)       THINK="$value" ;;
    --threads)     THREADS="$value" ;;
    --gpu-layers)  GPU_LAYERS="$value" ;;
    --cold)        COLD="$value" ;;
    --keep-alive)  KEEP_ALIVE="$value" ;;
    --timeout)     TIMEOUT="$value" ;;
    *) fail "Unknown option: $option" ;;
  esac
done

[[ -n "$MODEL" ]] || fail "Model cannot be empty"
[[ -n "$KEEP_ALIVE" ]] || fail "Keep-alive cannot be empty"
[[ "$OLLAMA_URL" =~ ^https?:// ]] ||
  fail "URL must start with http:// or https://"

OLLAMA_URL="${OLLAMA_URL%/}"

if [[ -n "$PROMPT_FILE" ]]; then
  [[ -f "$PROMPT_FILE" && -r "$PROMPT_FILE" ]] ||
    fail "Cannot read prompt file: $PROMPT_FILE"
  PROMPT="$(cat -- "$PROMPT_FILE")"
fi

[[ -n "$PROMPT" ]] || fail "Prompt cannot be empty"

if [[ -z "$OUTPUT" ]]; then
  OUTPUT="ollama-benchmark-$(date +%Y%m%d-%H%M%S)-$$.jsonl"
fi

# Capture the server version for reproducibility.
SERVER_INFO="$(curl -fsS --max-time "$TIMEOUT" \
  "$OLLAMA_URL/api/version")" ||
  fail "Cannot reach Ollama at $OLLAMA_URL"

SERVER_VERSION="$(jq -er '.version' <<< "$SERVER_INFO")" ||
  fail "Unexpected response from Ollama's version endpoint"

PAYLOAD="$(jq -n \
  --arg model "$MODEL" \
  --arg prompt "$PROMPT" \
  --argjson think "$THINK" \
  --arg keep_alive "$KEEP_ALIVE" \
  --argjson context "$CONTEXT" \
  --argjson tokens "$TOKENS" \
  --argjson temperature "$TEMPERATURE" \
  --argjson seed "$SEED" \
  --arg threads "$THREADS" \
  --arg gpu_layers "$GPU_LAYERS" '
  {
    model: $model,
    prompt: $prompt,
    stream: false,
    think: $think,
    keep_alive: $keep_alive,
    options: {
      num_ctx: $context,
      num_predict: $tokens,
      temperature: $temperature,
      seed: $seed
    }
  }
  | if $threads != "" then
      .options.num_thread = ($threads | tonumber)
    else . end
  | if $gpu_layers != "" then
      .options.num_gpu = ($gpu_layers | tonumber)
    else . end
')"

UNLOAD_PAYLOAD="$(jq -n --arg model "$MODEL" \
  '{model: $model, keep_alive: 0}')"

# Prevent overwriting an existing results file.
if ! (set -o noclobber; : > "$OUTPUT"); then
  fail "Cannot create results file: $OUTPUT"
fi

api_generate() {
  local body="$1"
  local response

  if ! response="$(curl --fail-with-body -sS \
    --max-time "$TIMEOUT" \
    "$OLLAMA_URL/api/generate" \
    -H 'Content-Type: application/json' \
    --data-binary "$body")"; then
    printf '%s\n' "$response" >&2
    return 1
  fi

  jq -e '
    if .error then error(.error)
    elif .done != true then error("Incomplete Ollama response")
    else .
    end
  ' <<< "$response"
}

unload_model() {
  api_generate "$UNLOAD_PAYLOAD" >/dev/null
}

# Record Ollama's reported model placement without requiring its CLI.
placement_snapshot() {
  local response
  if response="$(curl -fsS --max-time 10 "$OLLAMA_URL/api/ps")"; then
    jq -c '
      [.models[]? | {
        name,
        digest,
        size,
        size_vram,
        context_length
      }]
    ' <<< "$response"
  else
    printf 'null\n'
  fi
}

printf 'Model: %s | Runs: %s | Cold: %s | Ollama: %s\n' \
  "$MODEL" "$RUNS" "$COLD" "$SERVER_VERSION" >&2
printf 'Results: %s\n' "$OUTPUT" >&2

if [[ "$COLD" == false ]]; then
  printf 'Running one unmeasured warm-up...\n' >&2
  api_generate "$PAYLOAD" >/dev/null ||
    fail "Warm-up failed"
fi

for ((run = 1; run <= RUNS; run++)); do
  printf '\nRun %s/%s [%s]\n' "$run" "$RUNS" "$LABEL" >&2

  if [[ "$COLD" == true ]]; then
    unload_model || fail "Could not unload model before run $run"
  fi

  if ! response="$(api_generate "$PAYLOAD")"; then
    fail "Run $run failed; earlier results remain in $OUTPUT"
  fi

  placement="$(placement_snapshot)"

  result="$(jq -e \
    --argjson run "$run" \
    --arg label "$LABEL" \
    --arg version "$SERVER_VERSION" \
    --arg url "$OLLAMA_URL" \
    --argjson cold "$COLD" \
    --argjson request "$PAYLOAD" \
    --argjson placement "$placement" '
    def seconds:
      if . == null then null else . / 1000000000 end;

    {
      timestamp: (now | todateiso8601),
      run: $run,
      label: $label,
      model: .model,
      ollama_version: $version,
      ollama_url: $url,
      cold_start_requested: $cold,
      settings: {
        think: $request.think,
        keep_alive: $request.keep_alive,
        options: $request.options
      },
      prompt: $request.prompt,
      answer: .response,
      thinking: (.thinking // null),
      done_reason: .done_reason,
      hit_token_limit: (.done_reason == "length"),
      total_seconds: (.total_duration | seconds),
      load_seconds: (.load_duration | seconds),
      prompt_seconds: (.prompt_eval_duration | seconds),
      generation_seconds: (.eval_duration | seconds),
      input_tokens: .prompt_eval_count,
      cached_input_tokens: (.prompt_eval_cached_count // null),
      output_tokens: .eval_count,
      generation_tokens_per_second:
        (if (.eval_duration // 0) > 0 then
          .eval_count / (.eval_duration / 1000000000)
         else null end),
      loaded_models_after_run: $placement
    }
  ' <<< "$response")"

  jq -c . <<< "$result" >> "$OUTPUT"

  jq -r '
    def rounded:
      if . == null then "n/a"
      else ((. * 100 | round) / 100 | tostring)
      end;

    "  Generation: \(.generation_tokens_per_second | rounded) tokens/s" +
    " | Total: \(.total_seconds | rounded)s" +
    " | Load: \(.load_seconds | rounded)s" +
    " | Tokens: \(.output_tokens)" +
    " | Truncated: \(.hit_token_limit)"
  ' <<< "$result" >&2
done

jq -s --arg output "$OUTPUT" '
  def median:
    sort |
    length as $n |
    if $n == 0 then null
    elif $n % 2 == 1 then .[($n / 2 | floor)]
    else (.[($n / 2 - 1)] + .[($n / 2)]) / 2
    end;

  def stats:
    map(select(type == "number")) |
    if length == 0 then
      {min: null, median: null, mean: null, max: null}
    else
      {
        min: min,
        median: median,
        mean: (add / length),
        max: max
      }
    end;

  {
    model: .[0].model,
    label: .[0].label,
    ollama_version: .[0].ollama_version,
    runs: length,
    cold_start_requested: .[0].cold_start_requested,
    settings: .[0].settings,
    generation_tokens_per_second:
      (map(.generation_tokens_per_second) | stats),
    total_seconds: (map(.total_seconds) | stats),
    load_seconds: (map(.load_seconds) | stats),
    prompt_seconds: (map(.prompt_seconds) | stats),
    output_tokens: (map(.output_tokens) | stats),
    truncated_runs:
      (map(select(.hit_token_limit == true)) | length),
    results_file: $output
  }
' "$OUTPUT"
