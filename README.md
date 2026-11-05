# pi-loop

Runs [pi](https://github.com/earendil-works/pi) in a loop. Each round is a fresh `pi` run, so no session grows across rounds. Rounds share state through a context file.

## Requirements

- `pi`
- `jq`
- `timeout` or `gtimeout` (on macOS: `brew install coreutils`)

`loop.sh` does not need any pi extension.

## Install

```bash
git clone git@github.com:ravshansbox/pi-loop.git
ln -s "$PWD/pi-loop/loop.sh" /usr/local/bin/pi-loop
```

Any folder on your `PATH` works.

## Use

Write the task for every round in `prompt.md`, then run:

```bash
pi-loop
```

Each round:

1. Runs `pi --mode json` with `prompt.md`, `context.md` and these instructions: rewrite `context.md` as a short summary for the next round, commit your work, and write `done` to `status.txt` when nothing is left to do.
2. Shows each tool call with its main parameter.
3. Shows the worker's final reply, the round cost and the running total. The cost includes nested tool usage.
4. Saves the raw events in `.loop-logs/round-<n>.jsonl`.

The loop:

- exits with 0 when the worker writes `done` to `status.txt`
- exits with 1 when a round times out, is aborted or ends with a stop reason other than `stop`
- exits with 1 when it reaches the round limit
- warns when `context.md` grows past the size limit

The loop removes `status.txt` when it starts. pi saves each round as a normal session.

Add `.loop-logs/` and `status.txt` to your `.gitignore` so the worker does not commit them.

## Settings

| Variable | Default | Use |
| --- | --- | --- |
| `PROMPT_FILE` | `prompt.md` | The task for every round. |
| `CONTEXT_FILE` | `context.md` | Shared context between rounds. |
| `STATUS_FILE` | `status.txt` | The worker writes `done` here to stop the loop. |
| `MAX_ROUNDS` | `10` | The round limit. |
| `ROUND_TIMEOUT` | `30m` | The time limit for one round, in `timeout` format. |
| `CONTEXT_LIMIT` | `20000` | The size in bytes of `context.md` that triggers a warning. |
| `LOG_DIR` | `.loop-logs` | The folder for raw events. |

```bash
MAX_ROUNDS=5 ROUND_TIMEOUT=10m pi-loop
```

## Develop

```bash
shellcheck --severity=warning loop.sh tests/loop_test.sh tests/fake-pi/pi
bash tests/loop_test.sh
```

The tests run `loop.sh` against a fake `pi` in `tests/fake-pi`.
