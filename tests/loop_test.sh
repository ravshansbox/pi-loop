#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
passed=0
failed=0

write_round() {
  local file=$1 reply=$2 stop_reason=$3 aborted=$4
  {
    jq -cn '{type: "session", version: 3, id: "session-1"}'
    jq -cn '{type: "agent_start"}'
    jq -cn '{type: "tool_execution_start", toolCallId: "call-1", toolName: "bash", args: {command: "npm   test"}}'
    jq -cn '{type: "tool_execution_start", toolCallId: "call-2", toolName: "read", args: {path: "src/a.ts"}}'
    jq -cn '{type: "tool_execution_start", toolCallId: "call-3", toolName: "custom", args: {alpha: 1}}'
    jq -cn '{type: "message_end", message: {role: "toolResult", toolName: "custom", content: [], isError: false, usage: {cost: {total: 0.25}}}}'
    jq -cn --arg reply "$reply" --arg stop_reason "$stop_reason" '{type: "message_end", message: {role: "assistant", content: [{type: "text", text: $reply}], stopReason: $stop_reason, usage: {cost: {total: 0.5}}}}'
    jq -cn --argjson aborted "$aborted" '{type: "agent_settled", aborted: $aborted}'
  } >"$file"
}

setup() {
  work="$(mktemp -d)"
  fake="$work/.fake"
  mkdir -p "$fake"
  echo "Fix the next bug." >"$work/prompt.md"
  write_round "$fake/round.jsonl" "Fixed the parser." stop false
  path="$root/tests/fake-pi:$PATH"
}

run_loop() {
  (cd "$work" && env PATH="$path" FAKE_PI_DIR="$fake" "$@" "$root/loop.sh") >"$work/output" 2>&1
  echo $? >"$work/exit-code"
}

calls() {
  cat "$fake/calls" 2>/dev/null || echo 0
}

expect_exit_code() {
  [[ "$(cat "$work/exit-code")" == "$1" ]] || {
    echo "  expected exit code $1, got $(cat "$work/exit-code")"
    return 1
  }
}

expect_output() {
  grep -qF -- "$1" "$work/output" || {
    echo "  expected output to contain: $1"
    return 1
  }
}

expect_calls() {
  [[ "$(calls)" == "$1" ]] || {
    echo "  expected $1 pi calls, got $(calls)"
    return 1
  }
}

expect_argument() {
  grep -qF -- "$1" "$fake/args-1" || {
    echo "  expected pi to receive: $1"
    return 1
  }
}

minimal_bin() {
  local bin="$work/.bin" command_name
  mkdir -p "$bin"
  ln -s "$root/tests/fake-pi/pi" "$bin/pi"
  for command_name in "$@"; do
    ln -s "$(command -v "$command_name")" "$bin/$command_name"
  done
  path="$bin"
}

run_test() {
  local description=$1 test_function=$2 failure
  setup
  if failure=$("$test_function" 2>&1); then
    passed=$((passed + 1))
    echo "ok - $description"
  else
    failed=$((failed + 1))
    echo "not ok - $description"
    echo "$failure"
    sed 's/^/  | /' "$work/output" 2>/dev/null
  fi
  rm -rf "$work"
}

test_stops_when_done() {
  touch "$fake/done-2"
  run_loop && expect_exit_code 0 && expect_output "finished after 2 rounds" && expect_calls 2
}

test_stops_at_round_limit() {
  run_loop MAX_ROUNDS=3 && expect_exit_code 1 && expect_output "stopped after 3 rounds" && expect_calls 3
}

test_shows_tool_calls() {
  touch "$fake/done-1"
  run_loop && expect_output "bash  npm test" && expect_output "read  src/a.ts" && expect_output 'custom  {"alpha":1}'
}

test_shows_final_reply() {
  touch "$fake/done-1"
  run_loop && expect_output "Fixed the parser."
}

test_shows_cost() {
  touch "$fake/done-2"
  run_loop && expect_output "round 1 cost 0.7500 total 0.7500" && expect_output "round 2 cost 0.7500 total 1.5000"
}

test_stops_on_bad_stop_reason() {
  write_round "$fake/round.jsonl" "Something broke." error false
  run_loop && expect_exit_code 1 && expect_output "round 1 failed: stop reason error" && expect_calls 1
}

test_stops_when_aborted() {
  write_round "$fake/round.jsonl" "Stopped." stop true
  run_loop && expect_exit_code 1 && expect_output "round 1 failed: aborted" && expect_calls 1
}

test_stops_on_timeout() {
  echo 2 >"$fake/sleep-1"
  run_loop ROUND_TIMEOUT=1 && expect_exit_code 1 && expect_output "round 1 failed: exit status 124" && expect_calls 1
}

test_sends_prompt_and_context() {
  touch "$fake/done-1"
  run_loop && expect_argument "--mode" && expect_argument "@prompt.md" && expect_argument "@context.md" && expect_argument "status.txt"
}

test_reports_missing_prompt() {
  rm "$work/prompt.md"
  run_loop && expect_exit_code 1 && expect_output "missing prompt.md" && expect_calls 0
}

test_reports_missing_jq() {
  minimal_bin bash
  run_loop && expect_exit_code 1 && expect_output "missing dependency: jq"
}

test_reports_missing_timeout() {
  minimal_bin bash jq
  run_loop && expect_exit_code 1 && expect_output "missing dependency: timeout or gtimeout"
}

test_warns_on_large_context() {
  echo "a summary that is longer than ten bytes" >"$fake/context-1"
  touch "$fake/done-1"
  run_loop CONTEXT_LIMIT=10 && expect_output "warning: context.md is"
}

test_saves_raw_events() {
  touch "$fake/done-1"
  run_loop && cmp -s "$fake/round.jsonl" "$work/.loop-logs/round-1.jsonl"
}

test_ignores_old_status() {
  echo done >"$work/status.txt"
  run_loop MAX_ROUNDS=1 && expect_exit_code 1 && expect_calls 1
}

run_test "user runs the loop and it finishes when the worker writes done" test_stops_when_done
run_test "user runs the loop and it stops at the round limit when the worker never writes done" test_stops_at_round_limit
run_test "user sees each tool call with its main parameter while a round runs" test_shows_tool_calls
run_test "user sees the worker's final reply after each round" test_shows_final_reply
run_test "user sees the round cost and the running total including nested tool usage" test_shows_cost
run_test "user sees the loop stop when the final stop reason is not stop" test_stops_on_bad_stop_reason
run_test "user sees the loop stop when the run is aborted" test_stops_when_aborted
run_test "user sees the loop stop when a round exceeds the timeout" test_stops_on_timeout
run_test "worker receives prompt.md, context.md and the loop instructions in json mode" test_sends_prompt_and_context
run_test "user is told when prompt.md is missing" test_reports_missing_prompt
run_test "user is told when jq is not installed" test_reports_missing_jq
run_test "user is told when neither timeout nor gtimeout is installed" test_reports_missing_timeout
run_test "user is warned when context.md grows past the limit" test_warns_on_large_context
run_test "user finds the raw events of each round in the log directory" test_saves_raw_events
run_test "user runs the loop again and an old done status does not stop it early" test_ignores_old_status

echo "$passed passed, $failed failed"
((failed == 0))
