# Round trip: recovering a domain from a program

`hecks quality_control query target.round_trip` measures how much of a domain survives being implemented as
an ordinary program and then recovered from that program alone. The domain is generated
(`Fuzzing::DomainGenerator`), so no model has seen it and its bluebook is an exact answer key.

```
generated bluebook ──implementer──▶ program ──build, minify──▶ binary ──analyst──▶ recovered bluebook
        │ (answer key, sealed)                                                          │
        └──────────── battery: protocol scripts with Hecks's own answers ◀──── scored ──┘
```

## Running one round

1. **Prepare.** `hecks quality_control query target.round_trip arguments.value="prepare --seed 46 --out bench"`
   writes `bench/`: `key/` (the generated domain), `spec.bluebook` (a copy for the implementer),
   `PROTOCOL.md`, `prompts/` and `battery/` (scripts from `Fuzzing::SequenceGenerator`, rewritten in the
   protocol, each with Hecks's answers). It prints the battery's coverage gaps. A domain whose aggregate has a
   composite identity is refused; choose another seed.
2. **Implement.** Give an implementer `spec.bluebook`, `PROTOCOL.md` and `prompts/implementer.md`. Score the
   program: `score --bench bench --program "node main.js"`. Disagreements here are the implementer's drift.
3. **Build and seal.** Build and minify the program. Move `key/`, `battery/` and the implementer's source
   somewhere the analyst cannot read (an encrypted archive is enough), and delete the originals.
4. **Recover.** Give an analyst only the built program and `prompts/analyst.md`, in a fresh session.
5. **Score the recovery.** Restore the sealed files, then
   `score --bench bench --domain recovered [--verb-map Aggregate.Command=Aggregate.Other]`. The report counts
   step disagreements, the battery's coverage gaps, and, per category, the key's declarations found, missing
   and extra. A missing declaration fails the score even when no script exercised it.

Exit status: 0 prepared or agreed, 1 a disagreement or a missing declaration, 2 a usage error.

## What the first round showed (seed 46, renamed Harbor)

- The implementer's program matched Hecks on every step of a 2,569-step battery.
- The recovered domain matched on every step once one entry point was mapped, and declared every key fact
  except the four roles. Those were not in the program: the protocol names no caller, so the implementer
  could not enforce them, and no recovery from code can restore them. Rules that never reach code need
  interviews, not reverse engineering.

## Caveats

- **An implementer who reads Hecks's documentation writes Hecks-shaped code** (its refusal names, its
  reaction log), which makes recovery into Hecks easier than recovery of real legacy code. For a harder round,
  rewrite the spec as plain requirements and keep the implementer away from Hecks.
- **Generated domains are formulaic** (`Open`/`Close`/`Reopen` throughout), and their names also appear in
  `qa/stress_domains`. Rename the vocabulary, or tell the analyst not to search the repository.
- **A small battery can miss a rule.** The structural comparison catches a dropped declaration regardless;
  read the coverage gaps before trusting a clean behavioural score.
- **Policies the generator writes are often always refused** (`model_check`'s `forwarded_payload`); that is
  part of the spec an implementer must reproduce.
