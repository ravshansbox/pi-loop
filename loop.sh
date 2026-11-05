#!/usr/bin/env bash
set -euo pipefail

prompt_file="${PROMPT_FILE:-prompt.md}"
context_file="${CONTEXT_FILE:-context.md}"
status_file="${STATUS_FILE:-status.txt}"
max_rounds="${MAX_ROUNDS:-10}"
round_timeout="${ROUND_TIMEOUT:-30m}"
context_limit="${CONTEXT_LIMIT:-20000}"
log_dir="${LOG_DIR:-.loop-logs}"

fail() {
  echo "$1" >&2
  exit 1
}

for dependency in pi jq; do
  command -v "$dependency" >/dev/null || fail "missing dependency: $dependency"
done

if command -v timeout >/dev/null; then
  timeout_command=timeout
elif command -v gtimeout >/dev/null; then
  timeout_command=gtimeout
else
  fail "missing dependency: timeout or gtimeout"
fi

[[ -f "$prompt_file" ]] || fail "missing $prompt_file"
touch "$context_file"
mkdir -p "$log_dir"
rm -f "$status_file"

instructions="Shared context from earlier rounds is in $context_file. Before you finish, rewrite $context_file as a short summary for the next round. Commit your work. If nothing is left to do, write done to $status_file."

tool_line_filter='
  def field(selector): try selector catch null;
  select(.type == "tool_execution_start")
  | .args as $arguments
  | .toolName + "  " + (
      (
        field($arguments.display | strings)
        // field($arguments.display.name)
        // field($arguments.description)
        // field($arguments.command)
        // field($arguments.path)
        // field($arguments.pattern)
        // field($arguments.query)
        // ($arguments | tostring)
      )
      | tostring | gsub("\\s+"; " ") | .[0:120]
    )'

assistant_filter='[.[] | select(.type == "message_end" and .message.role == "assistant") | .message]'

total_cost=0

for ((round = 1; round <= max_rounds; round++)); do
  echo "round $round"
  log_file="$log_dir/round-$round.jsonl"

  pipeline_status=0
  "$timeout_command" "$round_timeout" pi --mode json "@$prompt_file" "@$context_file" "$instructions" </dev/null |
    tee "$log_file" |
    jq --unbuffered -r "$tool_line_filter" || pipeline_status=$?
  ((pipeline_status == 0)) || fail "round $round failed: exit status $pipeline_status"

  jq -rs "$assistant_filter | last | .content // [] | if type == \"string\" then . else map(select(.type == \"text\") | .text) | join(\"\") end" "$log_file"

  round_cost=$(jq -s '[.[] | select(.type == "message_end") | .message.usage.cost.total // 0] | add // 0' "$log_file")
  total_cost=$(jq -n --argjson total "$total_cost" --argjson round "$round_cost" '$total + $round')
  LC_ALL=C printf 'round %d cost %.4f total %.4f\n' "$round" "$round_cost" "$total_cost"

  aborted=$(jq -rs '[.[] | select(.type == "agent_settled") | .aborted] | last // false' "$log_file")
  [[ "$aborted" != true ]] || fail "round $round failed: aborted"

  stop_reason=$(jq -rs "$assistant_filter | last | .stopReason // \"none\"" "$log_file")
  [[ "$stop_reason" == stop ]] || fail "round $round failed: stop reason $stop_reason"

  context_size=$(($(wc -c <"$context_file")))
  if ((context_size > context_limit)); then
    echo "warning: $context_file is $context_size bytes, over the limit of $context_limit" >&2
  fi

  if [[ -f "$status_file" && "$(tr -d '[:space:]' <"$status_file")" == "done" ]]; then
    echo "finished after $round rounds"
    exit 0
  fi
done

echo "stopped after $max_rounds rounds" >&2
exit 1
