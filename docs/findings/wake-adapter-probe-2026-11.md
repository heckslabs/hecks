# Wake adapter probe: the default is the inbox Monitor (2026-11-21)

Work item: a-probe-picks-the-wake-adapter. Step 1 of the owner-confirmed messaging design.

**Decision: the default wake adapter is the inbox Monitor (`.claude/hooks/inbox_watch.sh`) paired
with the `PostToolUse` delivery of `Message.inbox`.** The board's push stream cannot wake a session.

## The two paths

(a) The bluebook knows one way to send: `Message.send!` (`lib/hecks/agents/agents.bluebook`,
aggregate `Message`). No adapter or port names a separate Claude cross-session message path, so (a) is
measured as `Message.send!` plus the next tool step delivering it.

(b) A Monitor on `127.0.0.1:4747/api/events`, or on the inbox poll in `inbox_watch.sh`.

## Does the push stream carry Message events?

No. Sampled twice for 20 to 25 seconds, once while a `Message.send!` ran: the stream carried only the
SSE events `tile`, `board`, `state` and `wiring`, each holding rendered HTML. No agents-domain
`MessageSent` or `MessageAddressed` event appears, so a Monitor on the stream cannot wake a session
for a message. Making it do so is a bluebook change on the board and a separate Work item.

## Numbers (this machine, n as stated)

| Measure | Result |
|---------|--------|
| `Message.send!` wall time (n=12) | 6.9 to 9.2 s, about 7.6 s |
| One inbox poll, `agents query message.inbox` (n=6) | 3.9 to 4.3 s, about 4.1 s |
| Monitor poll interval (`HECKS_WATCH_PAUSE`) | 30 s, so send-to-line latency is up to about 34 s, mean about 17 to 19 s |
| Delivery after the wake line (n=13 messages) | at the next tool step: every message appeared in that step, 13 of 13 |
| Message reaching `sent` for a live run (n=14) | 14 of 14 |
| Monitor lifetime | 58 turns of 30 s, under Monitor's 30 minute cap: one re-arm per 29 minutes |

Each poll boots `exe/hecks`, about 4 s of CPU per 30 s, so a watching session costs roughly 13% of
one core. Re-arming costs one assistant turn (one Monitor start) per 29 minutes, about 2 per hour of
an idle session. Whether an idle background session wakes without a Monitor is **not** measured: only
the Monitor and tool-step paths were run; the standing rule `rely-on-events` says a polled change in a
gap between Monitors is lost, though the message itself stays in the inbox until read.

## Reliability: outcomes the Message aggregate really has

| Probe | Outcome |
|-------|---------|
| Send to the own live run key | `sent`, then delivered by the tool-step hook, then read |
| Send twice with the same `message` key | refused: `[already_exists] Send creates a Message that already exists` |
| Send to a key that is no run (`no-such-run-xyz`) | stayed `addressed`, `refusal` null; the CLI process ran no decline reaction |
| Send to the standing seat `scrum-master` | stayed `addressed`, no `held` in the CLI process |
| Expired | no such outcome: the aggregate has no time attribute and no expiry command |

The last two rows differ from the bluebook's description (`Decline` and `Hold`): a `Message.send!` run
from the CLI leaves the message `addressed`; the declining and holding reactions are not run in that
process. Which process runs them is not established here.

## Consequences

- Duplicates are refused by name, so a retry with the same key is safe and silent.
- No expiry exists: a message for a dead run stays until read. A wake adapter must not assume one.
- Latency is dominated by the 30 s poll, not by delivery. A faster wake needs an event source that
  carries Message events, which the push stream does not yet.
