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

## Repeat: three runs, with and without `setsid`

Same real `claude` 2.1.330, `--model haiku`, `--max-turns 4`, `--setting-sources project`
(the owner's `~/.claude` settings and hooks are not loaded), `--allowedTools Bash`,
`--permission-mode bypassPermissions`, run in `/tmp/urgprobe/work`. Each case runs a 45 s
foreground loop that writes a marker file afterwards, interrupts it while `ps` shows it, waits 6 s,
then sends "Reply with the single word CONTINUED.". Plain cases run `bash -c '<loop>'`; `setsid`
cases run the same loop through `detach.py`, which calls `os.setsid()` first (macOS has no
`setsid` binary), so the loop is in its own process group apart from the Bash tool's shell.

Driver: `python3 -I /tmp/urgprobe/scripts/probe.py <case> plain|setsid` (script below). Verbatim
output of the plain cases 2 and 3 (case 1 is the same shape):

```
[t2-nosetsid-2] before interrupt (pid pgid sess command):
[t2-nosetsid-2]    17926 17926      0 /bin/zsh -c source /Users/christopheryoung/.claude/shell-snapshots/snapshot-zsh-1795385732551-z27wwo.sh 2>/dev/null || true && \builtin setopt NO_EXTENDED_GLOB NO
[t2-nosetsid-2]    17927 17926      0 bash -c for i in $(seq 1 45); do sleep 1; done; touch /tmp/urgprobe/work/marker-t2-nosetsid-2
[t2-nosetsid-2] 6s after interrupt, processes still running: 0
[t2-nosetsid-2] marker exists: False
[t2-nosetsid-2] OUT {"type":"control_response","response":{"subtype":"success","request_id":"int1","response":{"still_queued":[]}}}
[t3-nosetsid-3] before interrupt (pid pgid sess command):
[t3-nosetsid-3]    18952 18952      0 /bin/zsh -c source /Users/christopheryoung/.claude/shell-snapshots/snapshot-zsh-1795385743757-9e7ask.sh 2>/dev/null || true && \builtin setopt NO_EXTENDED_GLOB NO
[t3-nosetsid-3]    18953 18952      0 bash -c for i in $(seq 1 45); do sleep 1; done; touch /tmp/urgprobe/work/marker-t3-nosetsid-3
[t3-nosetsid-3] 6s after interrupt, processes still running: 0
[t3-nosetsid-3] marker exists: False
[t3-nosetsid-3] OUT {"type":"control_response","response":{"subtype":"success","request_id":"int1","response":{"still_queued":[]}}}
```

Verbatim output of the three `setsid` cases:

```
[s1-setsid-1] before interrupt (pid pgid sess command):
[s1-setsid-1]    45816 45816      0 /bin/zsh -c source /Users/christopheryoung/.claude/shell-snapshots/snapshot-zsh-1795386075916-iteizs.sh 2>/dev/null || true && \builtin setopt NO_EXTENDED_GLOB NO_B
[s1-setsid-1]    45817 45817      0 bash -c for i in $(seq 1 45); do sleep 1; done; touch /tmp/urgprobe/work/marker-s1-setsid-1
[s1-setsid-1] 6s after interrupt, processes still running: 0
[s1-setsid-1] marker exists: False
[s1-setsid-1] OUT {"type":"control_response","response":{"subtype":"success","request_id":"int1","response":{"still_queued":[]}}}
[s2-setsid-2] before interrupt (pid pgid sess command):
[s2-setsid-2]    46873 46873      0 /bin/zsh -c source /Users/christopheryoung/.claude/shell-snapshots/snapshot-zsh-1795386088024-gk5ttf.sh 2>/dev/null || true && \builtin setopt NO_EXTENDED_GLOB NO_B
[s2-setsid-2]    46874 46874      0 bash -c for i in $(seq 1 45); do sleep 1; done; touch /tmp/urgprobe/work/marker-s2-setsid-2
[s2-setsid-2] 6s after interrupt, processes still running: 0
[s2-setsid-2] marker exists: False
[s2-setsid-2] OUT {"type":"control_response","response":{"subtype":"success","request_id":"int1","response":{"still_queued":[]}}}
[s3-setsid-3] before interrupt (pid pgid sess command):
[s3-setsid-3]    47607 47607      0 /bin/zsh -c source /Users/christopheryoung/.claude/shell-snapshots/snapshot-zsh-1795386099289-6173u6.sh 2>/dev/null || true && \builtin setopt NO_EXTENDED_GLOB NO_B
[s3-setsid-3]    47608 47608      0 bash -c for i in $(seq 1 45); do sleep 1; done; touch /tmp/urgprobe/work/marker-s3-setsid-3
[s3-setsid-3] 6s after interrupt, processes still running: 0
[s3-setsid-3] marker exists: False
[s3-setsid-3] OUT {"type":"control_response","response":{"subtype":"success","request_id":"int1","response":{"still_queued":[]}}}
```

Result in all six cases: before the interrupt the loop ran (in the `setsid` cases in a pgid of
its own, different from the shell's); the interrupt was answered with `control_response`
`success`; the tool result was "The user doesn't want to proceed with this tool use", the turn
ended `result error_during_execution`; 6 s later no loop process remained, even the `setsid`
one, and no marker file was written; the next user message was answered `CONTINUED`
(`result success`) in the same session. No race showed in six runs. Survivors would have been
killed by pid and process group; none existed. `/tmp/urgprobe` was deleted afterwards.

### Scripts

`probe.py`:

```python
"""Drive real claude over stream-json stdin; interrupt a running foreground Bash tool."""
import json, os, signal, subprocess, sys, threading, time

WORK, LOGS, CLAUDE = "/tmp/urgprobe/work", "/tmp/urgprobe/logs", "/Users/christopheryoung/.local/bin/claude"
case, setsid = sys.argv[1], sys.argv[2] == "setsid"
marker = f"{WORK}/marker-{case}"
loop = f"for i in $(seq 1 45); do sleep 1; done; touch {marker}"
cmd = (f"python3 -I /tmp/urgprobe/scripts/detach.py {marker}" if setsid else f"bash -c '{loop}'")
prompt = f"Run exactly this one Bash command in the foreground, with no changes: {cmd}"
args = [CLAUDE, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--setting-sources", "project", "--permission-mode", "bypassPermissions",
        "--allowedTools", "Bash", "--max-turns", "4", "--model", "haiku"]
p = subprocess.Popen(args, cwd=WORK, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.STDOUT, text=True, start_new_session=True)
lines, log = [], open(f"{LOGS}/{case}.jsonl", "w")
def reader():
    for l in p.stdout:
        lines.append(l); log.write(l); log.flush()
threading.Thread(target=reader, daemon=True).start()
def send(o): p.stdin.write(json.dumps(o) + "\n"); p.stdin.flush()
def ps():
    out = subprocess.run(["ps", "-axo", "pid,pgid,sess,command"], capture_output=True, text=True).stdout
    return [l for l in out.splitlines() if marker in l and "ps -axo" not in l]
def results(): return sum(1 for l in lines if '"type":"result"' in l)
def note(*a): print(f"[{case}]", *a, flush=True)
send({"type": "user", "message": {"role": "user", "content": prompt}})
for _ in range(90):
    before = ps()
    if before: break
    time.sleep(1)
note("before interrupt (pid pgid sess command):"); [note("  ", l.strip()[:200]) for l in before]
send({"type": "control_request", "request_id": "int1", "request": {"subtype": "interrupt"}})
time.sleep(6)
after = ps()
note("6s after interrupt, processes still running:", len(after)); [note("  ", l.strip()[:200]) for l in after]
note("marker exists:", os.path.exists(marker))
for _ in range(30):
    if results() >= 1: break
    time.sleep(1)
send({"type": "user", "message": {"role": "user", "content": "Reply with the single word CONTINUED."}})
for _ in range(60):
    if results() >= 2: break
    time.sleep(1)
for l in lines:
    if '"control_response"' in l or '"type":"result"' in l: note("OUT", l.strip()[:400])
for l in after:
    try: os.kill(int(l.split()[0]), signal.SIGKILL)
    except Exception: pass
try: os.killpg(p.pid, signal.SIGKILL)
except Exception: pass
```

`detach.py`:

```python
"""Run the 45 s loop in its own session (setsid), then touch the marker."""
import os, sys
os.setsid()
loop = f"for i in $(seq 1 45); do sleep 1; done; touch {sys.argv[1]}"
os.execvp("bash", ["bash", "-c", loop])
```

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

Probe script: `claude -p` driven from Python 3 over pipes (see Scripts), `subprocess.Popen` with
`start_new_session=True`, writing the three stdin lines above and reading stdout lines of
stream-json; reproduce it from the sequence above.
