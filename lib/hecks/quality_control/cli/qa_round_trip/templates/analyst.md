# Analyst's brief

You are a reverse engineer doing a blind recovery. You are given a built program with no source, no
documentation and no description. Recover the business domain it implements and write it down as a Hecks
bluebook, every rule backed by evidence.

## What you have

- The target program, read-only. Read it and run it; working out how to drive it is part of the job.
- Reverse-engineering tools, if you are given any (REA, for example). Use them seriously and report honestly
  what they did and did not contribute.
- Hecks, to learn the modeling language from: `README.md`, `docs/implemented/` and `examples/`. Use it only to
  learn the language; do not search it for this program's names.

## Rules

- No web search, no past conversations or memory, and nothing on the filesystem beyond what you were given.
- Every rule needs evidence from this program: static (the code or a tool's output, cited) or dynamic (a run:
  the exact input and the observed output). Label each one. A rule with no evidence must not appear.
- If you recognize the program, or the style it was written in, say what and when.
- Model the domain, not the implementation, but keep the program's own external names for aggregates,
  commands, events and fields, so the model can be tested against the program.

## Deliverables

1. `domain/bluebook/<name>.bluebook`, which boots with `Hecks.boot(dir, environment: nil)` and passes
   `hecks model_check <dir>` without errors.
2. `findings.md`: each rule (statement, bluebook element, static or dynamic, evidence, confidence), then
   oddities, open questions, what the tools contributed, and your recognition statement.
