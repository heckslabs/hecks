# A package declares its own capabilities

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-24. Narrows [0098](0098-a-capability-names-a-duration-the-host-reads-from-the-ir.md) and [0099](0099-a-capability-names-a-word-and-a-field-the-host-reads-from-the-ir.md): their kinds stay, their contracts leave the language. A step toward [0094](0094-commerce-and-the-bluebook-registry-move-to-the-platform.md).

## Context

`Bluebook::Capabilities::CONTRACTS` defined every capability a chapter could provide. Some are read by Hecks itself: `authorization` (role checks), `membership` and `identity` (sign-in), `privacy` (masking) and `subject_keys` (the key vault). The rest (`newsletter`, `newsletter_issues`, `payments`, `registrations`, `payment_connection`, `checkout`) were read only by the Rust host's commerce code. The language still named every one of their keys, in the contracts, in a registry lookup each (`newsletter_provider_for` and the rest), in an exporter method each, in their own top-level `ir.json` keys, in the grammar's `provides` rows (and so the generated Rust parser table), and in the Rust build's seam table. A new product capability meant changing the language.

## Decision

1. **The language keeps the contracts it reads.** `CONTRACTS` holds the capabilities Hecks reads, each with exactly the keys it needs.
2. **Any other `provides` name is the package's own.** Each key must name exactly one thing the chapter declares, and the kind is read off the target: a command or query (`"Aggregate.Name"`), a port operation (`"Aggregate.Port.Operation"`, checked against the hecksagon at boot), a lifecycle mark (`"Aggregate.mark_name"`) or an attribute (`"Aggregate.attribute"`). A target that names nothing, or two kinds at once, is refused at build.
3. **`ir.json` carries one `provides` map.** Each package-declared capability exports as `provides.<name>`: `provider`, then one value per key. A verb exports qualified, a mark as its states, and an attribute as `{ "attribute": name, "default": filled default }`. The product top-level keys and their derived `aggregate` fields are gone; a reader derives an aggregate from its verb.
4. **The reader checks the keys it needs.** The host's `commerce_ir.rs` reads `provides.<name>`; a fact missing a key it requires reads as no provider, as before.
5. **The grammar admits a package's keys through one open `provides` row** (`kind: "pairs"`, no position, no name). The Rust parser accepts any text-valued key that row covers.

## Alternatives considered

- **A `capability` construct, so a package writes its own contract.** It would keep build-time key checks for package capabilities, but adds a construct (Ruby and Rust parser work) whose only reader today is code that is leaving Hecks. Rejected for now.
- **Infer an attribute's meaning from its default** (integer seconds, a word, else the name). It keeps the old value shapes but guesses. Rejected: the reader picks `attribute` or `default`.

## Consequences

- A misspelled package capability name is no longer refused by the language; the reader finds no provider.
- A host and the `ir.json` it reads must come from the same release, as they already do.
- Removing the product readers from the host (0094's move) no longer needs a language change.
