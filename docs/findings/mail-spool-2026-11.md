# The mail spool: a send appends one line (2026-11-22)

Work item: a-send-appends-to-a-spool-and-never-boots. Step 3 of the messaging design.

- **Send.** `.claude/hooks/mail_send.sh <message> <recipient> <sender> <kind> <body> [in_reply_to]`
  appends one JSON line to `~/.claude/hecks-dev/mail/spool.jsonl` (`HECKS_DEV_DIR` or
  `HECKS_MAIL_SPOOL` move it). It boots no domain. A line over 4000 bytes is refused, since only an
  append under PIPE_BUF is atomic.
- **Ledger.** `Agents::MailSpool` reads the spool a line at a time past its cursor
  (`spool.jsonl.cursor`) on each `Heartbeat.Beaten`, keeps each line as `Message.Send`, moves the
  cursor, and asks again until none is left. A replayed line is refused by its key. Mail waits in
  the spool while nothing ingests it.
- **Trust.** The sender is written as given; an ingested message is stamped unverified. Signed
  sends are for the off-laptop design.
- **Stall.** `wake-failed` (StallWatch): a `MessageSent` with no `MessageRead` after 10 minutes
  wakes the orchestrator. The minute count is written in the row, as every row does; no row reads a
  world setting.

## Not built here

- A bus that pushes from the spool, and a cursor per session that is the read receipt. Delivery
  still runs through the `Receive` hook, whose read the Message lifecycle records; the push stream
  carries no Message events (see the wake adapter probe).
- `question-unanswered` (read but unanswered after 30 minutes): a reply is a new Message naming
  `in_reply_to`, and a stall row cannot close on that match yet. It needs a closing rule on the
  event's `in_reply_to`, and a kind filter on `StallKind`.
- Spool rotation: the spool grows without bound and the cursor counts lines.
- A behaviors run reads the live default spool, as the Catcher's drain does.
