# Hecks bluebooks sit in four modules

**Status:** Proposed. Date: 2026-10-09. Every bluebook the gem carries serves one of four purposes, and nothing said so. The directories and the `"Hecks"` chapter mixed them. This names the four as DDD modules, a grouping above chapters, and splits the one place where two were mixed. Builds on ADR 0063 and ADR 0080 (sections 2 and 4).

## Context

ADR 0080 already sorts the attachable chapters into the language, the runtime and operations, and splits the `"Hecks"` chapter into a custodian half (a client operating a domain) and a codebase half (the maintainer's own work). A fourth purpose was never named: the work of keeping hecks itself well, which `codebase`, `hecks`, `Tickets` and `QualityControl` all do. And `custodian.bluebook` held two kinds of aggregate: ones that act on a domain that is running (`Host`, `Era`, `Operation`) and ones a developer uses while building a domain (`Introspection`, `ModelCheckRun`, `Package`, `Registry`, `Door`, `Build`, `FuzzRun`).

Chapter names cannot be the grouping. A chapter is named by the `Hecks.bluebook "Name"` header and that name is a key: the command namespace (`hecks deploy …`, `hecks quality_control …`), the journal and view names a store derives, the era translation files (`translations/` is keyed by chapter name), the `launcher` and `default_adapter` settings of the first-loaded chapter, and `Chapters.load_wiring`, which loads the ports and adapters of only the first file's directory. Merging chapters into four names would orphan journals, drop wiring silently and break every documented command line.

## Decision

This is a domain-side decision: which chapter and which aggregate belong together. It changes no adapter wiring.

1. **Four modules, a grouping above chapters.** A module is a set of chapters and aggregates that serve one purpose. Chapter names and the `"Hecks"` domain name do not change.

   | Module | Holds |
   |---|---|
   | Language | Bluebook, Hecksagon, World, Adapter, Port, Translation, Expression |
   | Runtime | Governance, Identity, Privacy, Compliance, ConsoleSettings, Tenancy, SME |
   | Operations | the custodian half of `"Hecks"` (`Operation`, `Host`, `Era`), Deploy, Site |
   | Maintenance | the codebase half and `hecks.bluebook` (`*Run`, `Release`, `SyntaxBootCache`), the tooling half (`Introspection`, `ModelCheckRun`, `Package`, `Registry`, `Door`, `Build`, `FuzzRun`), Tickets, QualityControl |

2. **`custodian.bluebook` is split by module.** It keeps `Operation`, `Host` and `Era`. A new `tooling.bluebook` holds the aggregates a developer uses while building a domain. Both declare `Hecks.bluebook "Hecks"`, so they merge into the same chapter as before: the IR of every aggregate, the aggregate and command names, the events, the journal names and the era shape (sorted by aggregate name) are unchanged. Only the load order of the aggregates changes.
3. **A behaviors file lists every file it loads.** The five `*.behaviors` files of `lib/hecks/hecks/` now load `tooling.bluebook` as well.
4. **Chapters stay in their directories.** `Chapters::GLOBS` names directories, and `load_wiring` reads one directory per chapter, so moving a chapter under a module directory buys nothing and risks silently dropping its ports. A module is stated here and by the file names, not by a directory tree.

## Consequences

- A reader can tell from this record, and from a file's header comment, which module a bluebook belongs to.
- `hecks help` groups, command names, events and stored data are unchanged.
- Where a new aggregate goes is decided by its purpose: acting on a running domain is Operations, building or maintaining one is Maintenance.

## Alternatives considered

- **Rename every chapter to one of four names.** Breaks the command lines, orphans journals and drops wiring, as in the Context.
- **A `module` keyword in the Syntax chapter.** The right place for the grouping to be machine-checked, but a new word is a language change of its own (`propose!` then `admit!`) and wants its own record.
- **Leave `custodian` whole.** Keeps the file the ADR 0080 table names, but leaves developer tooling grouped with what operates a running domain.

## Open items

- Whether `Site` is Operations or Runtime, and whether `Tenancy` is Runtime or Operations. They are placed above by what they do to a running domain, and either could move.
- Declaring modules in the language, and attaching a chapter by module.
