# 03: Client-name inventory

**Status:** Open (wayfinder ticket) · **Type:** research (AFK) · **Blocked by:** none · **Claimed by:** unclaimed
**Map:** [0064 client boundary](../0064-client-boundary-map.md)

## Question

Produce the facts the scrub is sized from: every external client or project name that appears in `origin/main`, where it appears, and whether it is prose or load-bearing.

- **The names are supplied by the owner when the research runs and are never written into this repository.**
- **Search** the tracked files of `origin/main`, case-insensitively, including generated code, corpus JSON, golden files and fixtures.
- **Report by area:** runtime code (`lib`, `rust`), scripts (`bin`), deploy recipes, docs and ADRs, the CHANGELOG, specs, fixtures and corpus, generated output. Give a count per name per area.
- **Classify each hit** as comment or prose, or load-bearing (an identifier used as data: a fixture aggregate name, a function name a spec depends on, a value inside a golden file or generated IR).
- **List the generated files** that would need regenerating if a load-bearing name is renamed, and the command that regenerates each.

Findings go on a throwaway `research/client-name-inventory` branch, with the pointer added below. Read-only.

## Findings

Not yet run.

## Decision

Not applicable. A research ticket is resolved when its findings are recorded and the tickets that wait on it are unblocked.
