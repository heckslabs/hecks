# 08: Platform tooling that belongs in Hecks

**Status:** Open (wayfinder ticket) · **Type:** grilling (HITL) · **Blocked by:** none · **Claimed by:** unclaimed
**Map:** [0064 client boundary](../0064-client-boundary-map.md)

## Question

The org's platform repo holds tooling for handing a project to a client. Some of it is generic mechanism and some is the org's own operating process. For each piece, decide: moves into Hecks, or stays in the platform.

| Piece | What it does | Hecks equivalent today |
| --- | --- | --- |
| Gem-pin check | Finds each Gemfile's Hecks pin, refuses path or git sources and a lockfile resolving from them, checks the version exists on the registry | none; release tooling lives in `bin/release_gem` |
| Schema dump and restore proof | Dumps one schema, restores into a scratch database, compares row counts, keeps the password out of argv | none |
| Boot boilerplate | Requires the era plugin explicitly before `Hecks.boot`, and repeats a bundler preamble across scripts | `Hecks.boot` does not load the era plugin itself |
| Handoff packaging | Exports a commit, scrubs the tree, scans for secrets, writes a deterministic archive and checksums, renders a handoff note | none; the exporter in `lib/hecks/projector` exports IR, not projects |
| Sync snapshot reader | Reads a deployed domain's snapshot and unwraps single-field value objects | none |

## Working recommendation (not a decision)

- Move the gem-pin check, the schema dump and restore proof, and the boot fix into Hecks: each is a small, independent, generic mechanism.
- Keep handoff packaging in the platform. It is the org's operator-only process, it strips the hosting layer on purpose, and its advisory rules name the org and its secret store. Moving it would publish that process and turn it into a supported Hecks API.
- Defer the sync snapshot reader until a second consumer exists.

## Decision

Not yet resolved.
