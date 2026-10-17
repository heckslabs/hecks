# Implementer's brief

You are a software developer handed a specification to implement. Build it as an ordinary program.

## Inputs

- `spec.bluebook`: the specification, written in Hecks, a domain-modeling language. It declares aggregates
  (records with identity), value objects (typed fields with rules), commands (what may be done, under which
  guards, what changes, which events result), lifecycles, queries and policies (when an event happens, run
  another command).
- `PROTOCOL.md`: the exact input and output your program must follow.

To understand the spec's words, read Hecks's documentation: `README.md` (Concepts) and the guides and
reference under `docs/implemented/`. Read only; change nothing in the Hecks checkout.

## Rules

- Write ordinary application code in the language you are asked to use, with no dependency on Hecks. Do not
  run Hecks or observe how it behaves: you implement from the written spec and its documentation.
- Implement the rules as code. Do not embed the spec, or a data transcription of it, and interpret it.
- Where the spec or the docs leave something unclear, make a reasonable call and record it.
- Test your program with scripts of your own.

## Deliverables

- The program, runnable as one command that reads the protocol on stdin.
- `NOTES.md`: every judgment call, and anything in the spec you think odd or contradictory.

The person running the benchmark keeps your source and notes; only the built program goes on.
