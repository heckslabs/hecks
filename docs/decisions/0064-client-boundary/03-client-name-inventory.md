# 03: Client-name inventory

**Status:** Resolved (research, 2026-09-26) · **Type:** research (AFK) · **Blocked by:** none · **Claimed by:** research subagent
**Map:** [0064 client boundary](../0064-client-boundary-map.md)

## Question

Produce the facts the scrub is sized from: every external client or project name that appears in `origin/main`, where it appears, and whether it is prose or load-bearing.

- **The names are supplied by the owner when the research runs and are never written into this repository.**
- **Search** the tracked files of `origin/main`, case-insensitively, including generated code, corpus JSON, golden files and fixtures.
- **Report by area:** runtime code (`lib`, `rust`), scripts (`bin`), deploy recipes, docs and ADRs, the CHANGELOG, specs, fixtures and corpus, generated output. Give a count per name per area.
- **Classify each hit** as comment or prose, or load-bearing (an identifier used as data: a fixture aggregate name, a function name a spec depends on, a value inside a golden file or generated IR).
- **List the generated files** that would need regenerating if a load-bearing name is renamed, and the command that regenerates each.

Read-only. The per-name detail is kept out of this repository, because writing it here would put the names in it.

## Findings

Run on 2026-09-26 against `origin/main` at `c5467a68`. The per-name counts, file paths and line numbers are in a local, unpushed file in the charting session's job directory (`tmp/03-client-name-inventory.md`); it is not committed anywhere. Neutral summary:

- **100 distinct files** contain at least one candidate name. About 78 are prose only (comments and docs; docs is the largest bucket at about 20 files) and about 22 are load-bearing.
- **Nothing** in `.github`, the README, golden files, examples, `qa` or generated docs.
- **Load-bearing clusters:**
  1. Two generated Rust modules whose IR embeds text copied from a fixture bluebook comment and from a framework vision string. CI fails if the source text changes without regeneration.
  2. Corpus JSON values in two files. They are passthrough arguments that scenarios never assert on, so a consistent rename is safe.
  3. Two host runtime constants: a default secret id, which is a real production secret name (renaming needs the secret and the deployment settings changed together), and a webhook description sent to the payment processor.
  4. Inline host test data, paired within each file.
  5. Ruby spec and script data: a Lambda client spec, a webhook spec's author, a QA seeding script that writes a proposer into the ledger, and an ignore-list entry.
  6. A policy string in the word-coverage spec that must name an external consumer, mirrored in a reference doc.
- **Regeneration:** `bin/project_rust spec/fixtures/rust_host/checkout_fixture` (or `bin/project_wasm` for the CI variant) and `bin/regen_codegen_domains`. Never project a single domain alone: the order affects attribution comments in shared generated modules. The CI gate is `bin/regen_codegen_domains --check`.
- **The org's own name, outside the registry keyword and path:** 66 files and about 146 hits. They are stack and deploy names, deploy templates, host auth comments, a deploy spec, and an example domain named for the org (about 340 hits, with generated output and a corpus file). This is a separate cluster, and ticket 01 has to say whether it counts.

## Decision

Not applicable. Findings recorded; ticket 11 now waits only on ticket 01.
