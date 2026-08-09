# Reference-existence checking is generated at the registry, not per-command

**Status:** Accepted — implemented. `rust/src/kernel/repository.rs`, `rust/project/{naming,domain_generator,registry}.rb`, branch `feat/rust-projection`. Closes one of the two remaining open items 0014/0016 both named (role checking, reference-existence checking) — the more tractable of the two, per 0014's own "roughly in order of tractability" list.

## Context

`CommandRules::References#resolve_references` (`lib/hecksagain/runtime/command_rules/references.rb`) is Ruby's own check that a `Reference<X>`-typed command argument actually names a record that exists — `Transfer.Request`'s `source`/`destination`, for instance. The generator has represented a reference as a bare `String` id since the very first slice (aggregates-and-value-objects.md's own framing: "a bare id... not a nested object"), but nothing checked that id ever named a real record. 0013 traced a real corpus mismatch to exactly this: `Transfer.Request` to a never-opened account (`xfer-ghost`) succeeded in Rust, ran its saga to a refused-and-compensated end, and left `Account#acct-8`'s ledger holding extra compensating entries Ruby's own ledger never has — because Ruby refuses the whole command before any saga starts at all.

## Decision

**Generate the check at the JSON router (`registry.rs`'s `dispatch_by_name`), not inside each command's own `dispatch_*` function.** This is a closer structural match to Ruby, not just a convenience: Ruby's own `resolve_references` reaches through `@registry.repository(domain, target)` — a repository OTHER than whichever aggregate's command is dispatching — and the router is the one place in the generated code that already holds a `store: &mut Store` with every aggregate's repo, not just the dispatching command's own. Doing this inside `emit_command`'s generated function instead would have meant growing that function's signature with one extra repo parameter per distinct referenced aggregate, for every command, purely to thread something the router already has.

Concretely:
- `check_reference` (`repository.rs`, hand-written, generic over `Repository<T>`) — `if value.is_empty() || repo.find(value).is_some() { Ok(()) } else { Err(Refusal::NotFound(...)) }`, wording matching Ruby's own `RefusalWording` template exactly: `"no {target} with {heads} {key}"`.
- `Projector.reference_target` (`naming.rb`) — parses `X` out of `Reference<X>`, the one piece of information `reference_type?`/`effective_scalar_type` already discarded (collapsing straight to `"String"`).
- `DomainGenerator.reference_checks` (`domain_generator.rb`) — per command, walks `command[:attributes]` for `Reference<X>` attributes and resolves `X` against `ir[:aggregates]` (the FULL list, not just what's been generated so far in the current pass — Ruby's own `attribute.type.resolve` is lazy through the same chapter, so a forward reference to an aggregate declared later in the same file already worked there; matched here by resolving against the whole IR up front). A target this domain never declares (cross-domain) or couldn't itself generate is skipped, matching Ruby's own `next unless target`.
- `Projector.emit_reference_check` (`registry.rb`) — one call per reference attribute, emitted into the router's match arm right after `from_json` succeeds and before the real `dispatch_*` call, matching Ruby's own `DISPATCH_ORDER` position (`resolve_references` runs after argument coercion, strictly before `hydrate`/`enforce_givens` — verified live during 0016's own investigation into this same file). An optional reference only checks when present (`if let Some(v) = &args.field { check_reference(...)?; }`), matching Ruby's own `next unless args.key?(...)` / `next if held.nil?`.

## Consequences

- Verified on the full corpus: matching instances went from 30/35 (0016's own count) to 31/35 — `Banking::Transfer#xfer-ghost` is now correctly refused up front in Rust, which also fixes the downstream `Banking::Account#acct-8` ledger mismatch (Ruby never posted the phantom compensating entries the old, unrefused saga run produced).
- **Three DISTINCT, previously-hidden gaps surfaced once this stopped masking smaller mismatches behind `xfer-ghost`'s bigger one** — none of them reference-existence checking: a scalar attribute's `pattern:` regex constraint (`EmailAddress.address`) isn't checked at all, a closed-set attribute declared `admits: "Other::ClosedSet"` (a subset import) accepts a member outside that admitted subset (`MovementDirection`'s `"sideways"`), and an `Integer`-typed JSON value arriving as a non-numeric string (`DailyLimit.cents: "lots"`) isn't refused. Flagged in `rust/project.rb`'s own header, not attempted here — each is a different layer (attribute-level pattern coercion, closed-set-subset membership, JSON scalar coercion) from what this pass touched.
- Full `bundle exec rspec` (1072 examples) and `bin/model_check` green.
- Role checking remains the one item left from 0014's original two-item list.

## Rejected alternatives

- **Threading extra repo parameters through each command's own `dispatch_*` function**, mirroring how `emit_command` already threads its OWN repo. Rejected: every one of the ~26 commands across banking + the self-hosted meta grammar with a reference-typed argument would need its generated signature to grow, for information the router already has one call site earlier — no benefit over doing the check exactly where Ruby's own version does, at the registry/router layer.
