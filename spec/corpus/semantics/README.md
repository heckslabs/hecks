# The semantics corpus

Implementation-neutral expected behaviour — the executable half of
`docs/semantics/bluebook-semantics.md`. Each fixture carries:

- `domain` — the example domain the steps run against
- `spec` — the clauses (C-numbers) this fixture pins
- `steps` — the same step shape `spec/corpus/rust_conformance` uses
- `expect` — the frozen outcome: ordered `refusals` **with `kind`**
  (the refusal class, C8.2), final `instances`, ordered `events`
  (without `occurred_at`, which is environmental — C7.3/C9.1)
- `ruby_only: true` — a fixture whose domain has no Rust cargo feature
  yet; it still gates the Ruby runtime

Expectations were seeded from the Ruby runtime ONCE
(`bin/seed_semantics_corpus`), reviewed against the clauses, and are
now the definition — not a recording of whatever Ruby currently does.
A runtime change that breaks a fixture is a semantics change: amend the
clause in `docs/semantics/bluebook-semantics.md` first, then reseed
that one fixture deliberately (`SEED=fixture_name
bin/seed_semantics_corpus`), and say why in the commit.

`spec/semantics_corpus_spec.rb` runs every fixture against the Ruby
runtime (Memory), and — io-tagged — against the compiled Rust kernel,
refusal kinds included. That makes this corpus the oracle both runtimes
answer to, where `spec/rust_conformance` only ever proved they agreed
with each other.
