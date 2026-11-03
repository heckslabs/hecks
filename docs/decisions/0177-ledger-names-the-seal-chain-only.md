# Ledger names the seal chain only

**Status:** Proposed. Date: 2026-11-02. Found by the ubiquitous-language survey of the same day;
Tickets findings `ul-ledger-four-meanings`, `ul-event-history-three-names` and
`ul-audit-two-meanings`. Builds on [ADR 0133](0133-a-journal-proves-it-was-not-rewritten.md).

## Context

ADR 0133 gave Hecks a seal: a SHA-256 chain over a journal's rows, recorded beside the journal,
so a later walk can show the journal was not rewritten. Its adapter is `lib/hecks/hecks/adapters/ledger.rb`
and the Rust host's is `rust/host/src/ledger.rs`. That is the meaning a reader of "ledger" expects:
a record that is evidence because it cannot be quietly changed.

Three other things carry the word and are not that.

| Name | Where | What it is |
|---|---|---|
| `ShapeLedger` | `lib/hecks/shape_ledger.rb` | The committed record of each bluebook's storage shape, read against the loaded bluebooks so a shape cannot change without a translation edge. It is a file under version control; git is its evidence, not a chain. |
| `TranslationLedger` | `lib/hecks/grammar/translation_ledger.rb` | A replay of `translation_rules.json` through the translation bluebook's own commands, to read back how each rule kind executes. It is a fixture replayed at boot. |
| `disposable_ledger` | `lib/hecks/adapters/driven/postgres_era/lineage_manager/disposable_ledger.rb` | A world word: a PostgresEra store whose rows are worth keeping but not worth an era. It is a mode of a store. |

Two neighbouring words have drifted the same way.

**The event history** has four names. `Runtime::EventLog` (`lib/hecks/runtime/event_log.rb`) is
the registry's in-memory Array of emitted events. The world verb `event_log` (`event_tap.rb`)
names the opt-in tap that writes that Array to a file. The persisted, append-only table is the
*journal* (`hecks_journal_<domain>`, ADR 0133). The Rust host's `ledger.rs` opens with "a domain's
lineage journal". QualityControl's pump reads "event logs". A reader cannot tell from the word
whether the history is in memory, on disk, or sealed.

**Audit** is two things. `Storehouse::Audit` (`lib/hecks/storehouse/audit.rb`) is the bus's JSONL
log of every dispatch, query and state call. The `Audit` aggregate (`lib/hecks/hecks/check/check.bluebook`)
is one walk of a journal's seal chain. The first records what was asked; the second checks what
was kept.

## Decision

1. **"Ledger" means the seal chain and nothing else.** `hecks/adapters/ledger.rb`, `rust/host/src/ledger.rs`
   and the `Seal` aggregate keep the word. No other class, file, world word or table carries it.

2. **The three others are named for what they are.**
   - `ShapeLedger` becomes `ShapeRecord`: the committed record of shapes. Its directory
     `lib/hecks/shape_ledger/` follows.
   - `TranslationLedger` becomes `TranslationReplay`, and `translation_rules.json` stays as the
     file it replays. The constant `TRANSLATION_LEDGER` becomes `TRANSLATION_RULES`.
   - The world word `disposable_ledger true` becomes `tooling_store true`. The module
     `DisposableLedger` becomes `ToolingStore`. The old word is refused by name with the new one in
     the message, as `install_doors:` was under ADR 0103.

3. **The event history is a journal when it is kept and a log when it is not.**
   - The append-only table stays the *journal*, in Ruby and in Rust. `ledger.rs`'s header drops
     "lineage journal" for "journal"; lineage is the era chain, which the journal belongs to but is
     not.
   - `Runtime::EventLog` stays `EventLog`: it is an in-memory log that a restart forgets, and the
     name says so.
   - The world verb `event_log` becomes `event_tap`, after the class that implements it, so the
     verb and the thing it switches on have one name.
   - QualityControl's descriptions say "journal" where they read a persisted history and "log"
     where they read a tap's file; [ADR 0176](0176-event-delivery-is-one-context-the-outbox-and-the-inbox-share.md)
     moves those aggregates and takes the wording with them.

4. **Audit is the walk; the call log is the trace.** The `Audit` aggregate keeps its name: it
   audits. `Storehouse::Audit` becomes `Storehouse::Trace`, its file `trace.rb`, and the JSONL file
   it writes a *trace*. `AUDIT_FIELDS` becomes `TRACE_FIELDS`.

## Consequences

- A reader who meets "ledger" anywhere in Hecks is reading about seals, and can trust the word the
  way ADR 0133 meant it.
- `disposable_ledger` is a world word, so a client world that declares it stops booting with a
  message naming `tooling_store`. The rename is breaking and rides the next major era with
  ADR 0163's renames.
- `event_log` is also a world word and carries the same consequence.
- The Ruby renames (`ShapeRecord`, `TranslationReplay`, `Storehouse::Trace`) are internal and
  break nothing a client pins.

## Alternatives considered

- **Keep "ledger" loose and let context disambiguate.** Rejected: ADR 0133 made the word carry a
  guarantee, and a `ShapeLedger` that git can rewrite dilutes it.
- **Rename the seals instead**, to `SealChain`, and leave the three. Rejected: three renames of
  things that are not ledgers is less work than teaching every reader of ADR 0133 a new word.
- **Call the in-memory history a journal too.** Rejected: a journal is kept; `EventLog` is not.

## Open question

- Whether `Storehouse::Trace` and the `Introspection` aggregate of the `operate` module are one
  thing. Both record what the runtime did. If they are, the trace becomes `Introspection`'s adapter
  rather than a module of its own; that is for the `operate` work under ADR 0163.
