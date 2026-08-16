---
name: bluebook-construct-creator
description: Add a new "declared once, referenced by name" resolution rule to the bluebook DSL (the S10 given-reference family) — propagate it through the Ruby builder, the self-hosted meta-domain, Rust's parser, real corpus, and docs, fast and bug-free. Use when the user asks to add a DSL sugar/resolution rule, reduce a real redundancy in the corpus grammar, or extend given/invariant/attribute-import-style reference mechanics to a new construct.
---

# Adding a bluebook resolution rule, fast

Five rounds of this exact workflow are on `main`: `sets :field` importing
an owner's attribute, `sets :list, append: {...}` importing a list
element's attribute, the ADR 0028 deferred-construction restructure that
removed the declaration-order limit both of those carried, `EntityBuilder
#given`, and `ValueObjectBuilder#invariant`'s own sibling-reference form.
This skill is that experience, operationalized — read it before starting
a sixth, don't re-derive it from scratch.

## 1. Pick the feature — real duplication, not a hypothetical

Grep the real corpus (`examples/banking/bluebook/banking.bluebook` is the
richest) for **byte-identical** description+predicate text repeated
across sibling constructs:

```
grep -n 'given("\|ensures("\|invariant("' examples/banking/bluebook/banking.bluebook
```

A real hit looks like two commands on the same entity, or two value
objects on the same aggregate, declaring the exact same `description` AND
the exact same predicate body. That is your corpus motivation — cite it
in the commit message, don't invent a synthetic example.

**Selection filter — reject a candidate if:**

- It would need **new runtime enforcement semantics**, not just builder-
  time desugaring. Check `lib/hecksagain/runtime/command_rules/
  admissibility.rb` and `lib/hecksagain/runtime/entity_interpreter.rb`
  first — if the runtime doesn't already generically iterate the field
  you're about to populate (the way `enforce_givens`/`enforce_invariants`
  already iterate `command.givens`/`aggregate.invariants` regardless of
  where the entry came from), you've picked a feature, not a sugar. Real
  miss this arc made: `EntityBuilder#invariant` was rejected mid-round
  because `Admissibility#enforce_invariants`'s own comment says "there is
  no separate entity invariant... on purpose" — building it properly
  meant new `EntityInterpreter` enforcement, a different and much bigger
  task than declaration sugar.
- The predicate text would need to be REWRITTEN to be shared (e.g. one
  side reads `customer.status`, the other needs `parent.customer.status`
  for the identical idea) — not resolvable by copying a `Given`/
  `Invariant` struct verbatim, so out of scope for this pattern.

**The shape, once you've found a real hit:** the referencing builder
method already exists somewhere with a REQUIRED-block signature. Give it
an optional block: `def word(description, &predicate); return
reference_named_word(description) unless predicate; ...`. Mirror
`CommandBuilder#given`'s own `reference_named_given` (`lib/hecksagain/
bluebook/dsl/command_builder.rb`) — that's the canonical shape every
round since has copied.

## 2. Isolated worktree, always

```
git worktree add .claude/worktrees/<short-name> -b feature/<short-name>
cd .claude/worktrees/<short-name>
```

## 3. Spine — Ruby only, smoke-tested before anything else

Write the builder change. Thread the "owner pool" the reference resolves
against the same way every prior round did — `owner_attributes:`/
`owner_constructs:`/`owner_value_objects:`/`named_givens:`, passed from
the parent builder's own already-built collection at the point the child
builder is constructed.

Smoke-test immediately, in-process, WITHOUT `Hecks.boot` (too heavy — it
wires live adapters and will hang on a Postgres-backed domain like
`compliance`). Use the lightweight path every round's smoke test and
`Hecksagain::Codemod` both use:

```ruby
registry = Hecksagain::Runtime::Registry.new
Hecksagain.with_registry(registry) do
  Kernel.load("lib/hecksagain/ports/persistence.port")
  Kernel.load("lib/hecksagain/ports/extraction.port")
  Kernel.load("lib/hecksagain/adapters/driven/memory.adapter")
  Kernel.load("lib/hecksagain/adapters/driven/prism.adapter")
  Hecks.bluebook "Pilot" do
    # the exact real-corpus shape you found in step 1, minimal
  end
end
```

## 4. Fan out — Rust mirror dispatched NOW, not after propagation

**Dispatch the Rust-mirror agent immediately after the spine smoke-test
passes** — before corpus migration, before self-hosting propagation,
before docs. It only needs the spine diff. This was gotten wrong once
(round 4 serialized it, costing ~2 minutes) and gotten right the next two
rounds by just doing it first. Give the agent:

- The exact spine diff (`git diff <builder files>`).
- The real corpus example from step 1.
- Which Rust file owns the matching construct's parser
  (`rust/parser/src/parse/{aggregate,entity,command,value_object}.rs`) —
  point it at the sibling `try_reference_named_*` function if one already
  exists (`command.rs`'s `try_reference_named_given` is the template
  every subsequent Rust mirror has copied one construct over).
- Explicit scope: `rust/` only, no `git commit`, don't touch `lib/`/
  `docs/`/`bin/`/`spec/`/`examples/`.
- Verify-before-finish requirements: `cargo test --no-fail-fast` in
  `rust/parser`, and `bundle exec rspec spec/parser_parity_spec.rb --tag
  io` green, specifically naming which corpus members must pass.

While it runs, do steps 5–7 yourself in the same worktree (disjoint
files — no conflict).

## 5. Self-hosting propagation — ONLY if you added a new `Construct#field`

Skip this whole section if your feature reuses an EXISTING IR field (like
`ValueObjectBuilder#invariant`'s reference form — `ValueObject#invariants`
already existed, zero propagation needed, round done in ~15 min). If you
added a genuinely new field to a Ruby IR class's `emits_ir` (like `Entity
#preconditions` in round 4), do ALL SIX of these **in one pass**, before
running anything — this is the checklist that turned round 4's five
reactive `rspec` loops into what should be one:

1. **Grammar table** (`lib/hecksagain/language/bluebook/syntax.bluebook`)
   — two rows: a Keyword row (`context:`, `body: "source"`, `fills:
   "yourfield"`) and an Argument row (`at: "1"`, `kind: "text"`, `fills:
   "description"`), copied from the sibling construct's own existing
   rows for the same word.
2. **Meta-domain description** (`lib/hecksagain/language/bluebook/
   <construct>.bluebook`) — `attribute :yourfield, list_of(Rule)` (reuse
   the sibling construct's own `Rule`-shaped value object pattern:
   `{description: String, canonical: String}`, declared fresh per
   aggregate — meta-domain value objects are NOT shared across
   aggregates in this codebase), plus a `command "YourWord"` mirroring
   the sibling construct's own attach-command (e.g.
   `Aggregate.Precondition`) that `sets :yourfield, append: {...}`.
3. **`Assembly::Contracts`** (`lib/hecksagain/bluebook/assembly/
   contracts.rb`) — add `yourfield: [:yourfield, [:each, :given]]` to
   `fields:` and `yourfield: [:each, :rule]` to `reads:`, in the
   construct's own `Contract.new(...)` block.
4. **`MetaValidator::Reconstruction`**'s hand-typed reader
   (`lib/hecksagain/bluebook/meta_validator/reconstruction.rb`) — ONLY
   `aggregate(row)` and `entity(row)` are hand-typed today (everything
   else reads generically through Contracts' `declaration()`). If your
   construct is one of these two, add `yourfield: Array(row[:yourfield])
   .map { |held| rule(held) }` to its returned hash. **This is the step
   most likely to be silently skipped** — it produces zero test failure
   until either real corpus content exercises the field OR you run
   `spec/round_trip_spec.rb`'s "hand-typed reconstruction methods return
   every key their construct's own IR declares" test (added specifically
   to catch this — run it explicitly, see step 6).
5. **Fuzzer claim** (`lib/hecksagain/fuzzing/properties.rb`) — add
   `"YourConstruct#yourfield"` to whichever `FEATURE_COVERAGE` property
   already claims the sibling construct's equivalent field (a bare
   reference just pushes the same struct onto the referencing command's
   own already-covered list — it "closes for free," name that reasoning
   in a comment the same way `Aggregate#preconditions`'s own entry does).
6. **Regenerate generated artifacts**, once, at the end:
   `GOLDEN=rewrite bundle exec rspec spec/ir_golden_spec.rb`, `ruby
   bin/project_oidc <domain>` for any stale manifest, `bin/reference` for
   docs (see step 6 for how to tell if one's stale).

## 6. Proactive checks — run these YOURSELF before the first commit

Don't let the post-commit hook or a fifth `bundle exec rspec` discover
these one at a time. Run explicitly, before committing:

```
bundle exec rspec spec/syntax_conformance_spec.rb          # new grammar row wired correctly
bundle exec rspec spec/fuzzing/meta_domain_coverage_spec.rb --tag fuzzing   # new field has a claim
bundle exec rspec spec/round_trip_spec.rb                  # Reconstruction returns every ir_spec key
bundle exec rspec                                            # full suite
bin/doc_coverage
bin/model_check
```

If you migrated real corpus text, write the doc prose demonstrating it
(`docs/reference/<construct>.md`, matching the existing "## word" section
pattern — generated table stays inside the markers, hand-written prose
goes below it) BEFORE running `bin/doc_coverage`, or it will name the gap
for you.

## 7. Full sweep, commit, merge, push

Once the Rust agent reports back (cargo test + parser_parity green) and
your own steps 5–6 are clean:

```
bundle exec rspec spec/parser_parity_spec.rb --tag io   # confirm again post-Rust-merge
git add -A && git commit -m "..."
```

**If the post-commit hook (or anything) surfaces a real gap anyway**, fix
it, then `git commit --amend` — never leave a red commit in history, and
never layer a second "fix" commit on top. Re-run the full gate sweep
after amending, as the official bug-free confirmation, before merging.

```
cd /path/to/main/checkout
git merge --no-ff feature/<short-name> -m "..."
bundle exec rspec   # confirm on main post-merge — catches conflicts with concurrent unrelated work
git push origin main
git worktree remove .claude/worktrees/<short-name>
git branch -d feature/<short-name>
```

## 8. Report the benchmark

Timestamp at worktree creation and at push (`date +%s` bracketing the
whole round is enough — no need for finer granularity unless something
went wrong and you want to name which phase cost the time). Recent real
numbers, for calibration: a new-`Construct#field` round (grammar + meta-
domain + Contracts + Reconstruction + fuzzer + corpus + Rust, discovered
reactively) took ~27 minutes; the same category done with this checklist
plus a parallel Rust dispatch should land nearer 17–19 minutes. A round
that reuses an existing IR field (pure builder sugar, no propagation
needed) took ~15 minutes, dominated by the Rust mirror and verification,
not discovery.

## Known pitfalls, already paid for once — don't re-pay them

- **Rust's parser has no block to defer the way Ruby does.** If your
  spine change relies on `entity`/`command`/`query` being deferred
  (ADR 0028's shape), Rust's mirror defers by recording *where* a body
  starts in the token stream and skipping over it, not by queuing an
  unevaluated closure — tell the Rust agent this explicitly if relevant,
  don't let it discover it.
- **The exported IR is array-order-sensitive.** If your feature imports a
  value into a list a caller already declared some entries of, appending
  at the end is wrong unless the imported value is provably always last.
  Treat resolution as filling a gap at its ORIGINAL declared position,
  not appending — round 2's `resolve_append_fields!` names the exact bug
  this caused when it was gotten wrong first.
- **A process-lifetime cache can go stale if anything reloads an edited
  file in-process** (`Hecksagain::Adapters::Prism`, if you're scripting a
  corpus migration rather than hand-editing) — use `Prism.forget(path)`/
  `Prism.forget_all`, not a bare re-`Kernel.load`.
- **`Hecksagain::Codemod`** (`lib/hecksagain/codemod.rb`) already exists
  for scripted corpus migration when the yield is large enough to justify
  it (more than a handful of hand-edits) — extend it with two rule-
  specific procs (`find_candidates`, `apply_candidate`) rather than
  writing a new boot/safety-net harness from scratch.
- **`docs/resolution-rules/`** is where each shipped rule's exact
  algorithm is written down, language-agnostic, for a future Rust-mirror
  agent to read as its primary source of truth. Write one for a
  genuinely new resolution rule (not needed for a rule that's just the
  same mechanism on a new construct, like this skill's own rounds 4–5 —
  only for a new ALGORITHM, like rounds 1–2's order-preservation logic).
