# Urgent interrupt probe

Question: when a running turn is interrupted, is a running foreground Bash command killed, and can
the session carry on with a new message? Measured against the real `claude` 2.1.330
(`/Users/christopheryoung/.local/bin/claude`), model `haiku`, on 2026-11-22. Claude's stream-json
control requests are version-specific, so this finding expires with that version.

## Setup

- Temp directory `/tmp/urgprobe/work`, outside the repo; the script lived in `/tmp/urgprobe/scripts`.
- Isolation: `--setting-sources project` (the temp directory has none), so the owner's `~/.claude`
  settings and hooks are not loaded and no live ledger or event tap is reached.
- Permission: `--permission-mode bypassPermissions --allowedTools Bash`, in the temp directory only.
  Cost cap: `--max-turns 4`, `--model haiku`, one run.
- Command: `claude -p --input-format stream-json --output-format stream-json --verbose ...`.
- Sequence: send a user message asking for
  `for i in $(seq 1 45); do sleep 1; done; touch /tmp/urgprobe/work/marker`; wait until `ps` shows
  that shell running; send on stdin
  `{"type":"control_request","request_id":"int1","request":{"subtype":"interrupt"}}`; wait 6 s,
  `ps` again; send a second user message "Reply with the single word CONTINUED."
- Cleanup: survivors killed with `pkill` and the process group; none remained; temp directory removed.

## Observed

| Step | Result |
| --- | --- |
| Before the interrupt | the Bash tool's `zsh -c` shell (pgid 94351) was running the loop |
| Interrupt request | answered `control_response` `success`; the tool result was "The user doesn't want to proceed with this tool use"; the turn ended with `result error_during_execution` |
| 6 s later | no process of the loop remained; the marker file was never written |
| Second user message | the same session answered `CONTINUED` (`result success`) |

A first run used `sleep 47 && touch ...`. Claude's harness refused that foreground form and ran
it as a background task, and the interrupt did not kill the background task. That run says nothing
about a foreground command; only a command that stays in the foreground was killed.

## Finding

A streaming-input `claude -p` session kills a running foreground Bash tool on `interrupt`, ends the
turn, and continues with the next user message. A background Bash task survives it.

## Recommendation

`lib/hecks/hecks/adapters/session_line.rb:41` starts every run as `... --bg -- <brief>`: claude's
daemon holds the session, so there is no stdin to write a control request to. Using this needs runs
hosted as streaming children, which changes ownership, resume, `Fleet` halt and revive and the
`AgentRun` ledger. File that as a Work item for the owner of the wake port, together with the
question of what marks a message urgent (`Message.kind` is one of answer, brief-change, stand-down,
question, owner, report, blocked, done). Nothing else is built here.

Probe script: `claude -p` driven from Python 3 over pipes, `subprocess.Popen` with
`start_new_session=True`, writing the three stdin lines above and reading stdout lines of
stream-json; reproduce it from the sequence above.
