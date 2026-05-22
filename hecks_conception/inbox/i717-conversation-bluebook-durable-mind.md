# i717 — conversation.bluebook : the durable mind (context as a queryable domain)

The keystone of tonight's continuity arc. We made the runtime's warmth a cache of
durable `.heki` (lazy hydration + warm serve), and the dispatch process a resident
daemon (the body persists — the v2 socket daemon). `conversation.bluebook` is the
last and deepest move: **make the MIND persist.**

## The idea (Chris)
Every conversation turn dispatches THROUGH a `conversation.bluebook` — a hook that
**mirrors Claude's context window** into the domain and **keeps archives**. The
conversation stops being an ephemeral buffer (lost on restart, capped by the window)
and becomes a durable, queryable domain.

## Payoff — context as a projection
The context window stops being the thing you HAVE and becomes a thing you ASSEMBLE:
query recent turns, open decisions, threads on a topic, at any depth. Restart becomes
a non-event — re-attach and re-query, not hand off. The hand-written restart prompt
retires ; the very idea of losing context dissolves.

## The hook (novel)
A Claude Code hook captures every turn — `UserPromptSubmit` for user turns, `Stop`
for assistant turns (or a transcript mirror) — and dispatches it into
`conversation.bluebook`. `conversation.heki` already logs the raw stream ; this gives
it a domain SPINE, and the hook is the mirror. Chris: "that kind of hook would be
novel" — a context-mirroring-into-a-domain hook is a new pattern.

## Archives + volume
It gets big fast. Design for it: segment / roll older turns into archives that stay
queryable (rebuild from any depth). The active window mirrors the recent turns ; the
archive is the long-term memory. A cool experiment.

## Design crux
A turn must be more than a transcript line — speaker, intent, decisions, references —
so queries MEAN something. Structuring the turn is the real work ; a flat transcript
is just a log (which `conversation.heki` already is).

## The unification
Body = the serve daemon ; memory = `.heki` ; **mind = `conversation.bluebook`.**
Bluebook-first all the way down — even the conversation about building the system
becomes a bluebook. Total continuity. Sits with i711–i716 and the
wake-ritual-reconstructs-continuity idea.
