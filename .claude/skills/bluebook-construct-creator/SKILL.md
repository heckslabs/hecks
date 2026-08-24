---
name: bluebook-construct-creator
description: Add a new "declared once, referenced by name" resolution rule to the bluebook DSL (the S10 given-reference family) — propagate it through the Ruby builder, the self-hosted meta-domain, Rust's parser, real corpus, and docs, fast and bug-free. Use when the user asks to add a DSL sugar/resolution rule, reduce a real redundancy in the corpus grammar, or extend given/invariant/attribute-import-style reference mechanics to a new construct.
---

# Adding a bluebook resolution rule, fast

Nine rounds of this exact workflow are on `main`: `sets :field` importing
an owner's attribute, `sets :list, append: {...}` importing a list
element's attribute, the ADR 0028 deferred-construction restructure that
removed the declaration-order limit both of those carried, `EntityBuilder
#given`, `ValueObjectBuilder#invariant`'s own sibling-reference form,
cross-entity given sharing (one piece's own `given`, shared with any
sibling piece under the same aggregate —
`docs/resolution-rules/cross-entity-given.md`), chapter-wide given sharing
(one aggregate's own `given`, shared with any other aggregate in the same
chapter — `docs/resolution-rules/chapter-given.md`), a reusable "hoist
un-shared local declarations" codemod (`bin/codemod_hoist_local_givens`,
generalizing the exact fix LedgerEntry got by hand in round 4), and
`EntityBuilder#invariant` (a genuinely new IR field + real, additive
runtime enforcement — the one round in this list that ISN'T pure builder
sugar; see its own note in "Pick the feature," below). This skill is that
experience, operationalized — read it before starting a tenth, don't
re-derive it from scratch.

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
  time desugaring. Check `lib/hecks/runtime/command_rules/
  admissibility.rb` and `lib/hecks/runtime/entity_interpreter.rb`
  first — if the runtime doesn't already generically iterate the field
  you're about to populate (the way `enforce_givens`/`enforce_invariants`
  already iterate `command.givens`/`aggregate.invariants` regardless of
  where the entry came from), you've picked a feature, not a sugar. This
  is a REAL DISQUALIFIER for the fast workflow this skill covers, but not
  necessarily a dead end forever — `EntityBuilder#invariant` was rejected
  on exactly this basis once (`Admissibility#enforce_invariants`'s own
  comment: "there is no separate entity invariant... on purpose," since
  an entity mutation already re-checks the enclosing aggregate), then
  later BUILT successfully as a real, bigger round once there was
  explicit appetite for the larger scope: the resolving design was NOT a
  separate enforcement path — `enforce_invariants` gained an ADDITIVE
  recursive walk (checking every INSTANCE an entity-holding list attribute
  contains against that piece's own declared rules, reusing
  `EntityInterpreter#element_of`'s own `list?`/`type.to_s == entity_name`
  instance-discovery lookup and `enforce_givens`'s own `parent:`-threading
  shape) — recognizing that "every element of a list-of-pieces
  individually satisfies its own shape" was already part of what the
  aggregate's own consistency meant, not a new boundary. If a rejected
  candidate later gets real appetite, look for this same move first: can
  the "new enforcement" be phrased as an ADDITIVE extension of an
  existing check-loop, rather than a genuinely parallel enforcement path,
  before assuming it needs one.
- The predicate text would need to be REWRITTEN to be shared (e.g. one
  side reads `customer.status`, the other needs `parent.customer.status`
  for the identical idea) — not resolvable by copying a `Given`/
  `Invariant` struct verbatim, so out of scope for this pattern.

**The shape, once you've found a real hit:** the referencing builder
method already exists somewhere with a REQUIRED-block signature. Give it
an optional block: `def word(description, &predicate); return
reference_named_word(description) unless predicate; ...`. Mirror
`CommandBuilder#given`'s own `reference_named_given` (`lib/hecks/
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
`Hecks::Codemod` both use:

```ruby
registry = Hecks::Runtime::Registry.new
Hecks.with_registry(registry) do
  Kernel.load("lib/hecks/ports/persistence.port")
  Kernel.load("lib/hecks/ports/extraction.port")
  Kernel.load("lib/hecks/adapters/driven/memory.adapter")
  Kernel.load("lib/hecks/adapters/driven/prism.adapter")
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
- **Explicit worktree instruction, every time, no exceptions**: "create
  and work in your OWN fresh isolated worktree — `git worktree add`,
  never edit files directly in the shared main checkout, including for
  any follow-up step after your main commit." Say this even though it
  seems obvious; it has been violated twice by different agents, each
  time leaving an orphaned, uncommitted edit sitting in the shared
  checkout that blocked an unrelated sibling round's own merge (see
  "Known pitfalls," below).
- Verify-before-finish requirements: `cargo test --no-fail-fast` in
  `rust/parser`, and `bundle exec rspec spec/parser_parity_spec.rb --tag
  io` green — name EVERY corpus member that must pass, not just the one
  your own real-corpus example touches; the self-hosted meta-domain
  (`bluebook_language`) can independently exercise the same new
  construct in its own grammar description of itself, and missing that
  is exactly how a round has shipped with real, silent Rust breakage
  before.

While it runs, do steps 5–7 yourself in the same worktree (disjoint
files — no conflict). Once it reports back, INDEPENDENTLY re-run
`bundle exec rspec spec/parser_parity_spec.rb --tag io` yourself before
treating the round as finished — this spec is tagged `:io` and excluded
from both the default `bundle exec rspec` run and the pre-push hook's
own default profile, so trusting a green gate sweep (yours or an agent's)
without this explicit re-run is exactly how "Rust mirror not yet
dispatched" has slipped onto `main` unnoticed before.

## 5. Self-hosting propagation — ONLY if you added a new `Construct#field`

Skip this whole section if your feature reuses an EXISTING IR field (like
`ValueObjectBuilder#invariant`'s reference form — `ValueObject#invariants`
already existed, zero propagation needed, round done in ~15 min). If you
added a genuinely new field to a Ruby IR class's `emits_ir` (like `Entity
#preconditions` in round 4), do ALL SIX of these **in one pass**, before
running anything — this is the checklist that turned round 4's five
reactive `rspec` loops into what should be one:

1. **Grammar table** (`lib/hecks/language/bluebook/syntax.bluebook`)
   — two rows: a Keyword row (`context:`, `body: "source"`, `fills:
   "yourfield"`) and an Argument row (`at: "1"`, `kind: "text"`, `fills:
   "description"`), copied from the sibling construct's own existing
   rows for the same word.
2. **Meta-domain description** (`lib/hecks/language/bluebook/
   <construct>.bluebook`) — `attribute :yourfield, list_of(Rule)` (reuse
   the sibling construct's own `Rule`-shaped value object pattern:
   `{description: String, canonical: String}`, declared fresh per
   aggregate — meta-domain value objects are NOT shared across
   aggregates in this codebase), plus a `command "YourWord"` mirroring
   the sibling construct's own attach-command (e.g.
   `Aggregate.Precondition`) that `sets :yourfield, append: {...}`.
3. **`Assembly::Contracts`** (`lib/hecks/bluebook/assembly/
   contracts.rb`) — add `yourfield: [:yourfield, [:each, :given]]` to
   `fields:` and `yourfield: [:each, :rule]` to `reads:`, in the
   construct's own `Contract.new(...)` block.
4. **`MetaValidator::Reconstruction`**'s hand-typed reader
   (`lib/hecks/bluebook/meta_validator/reconstruction.rb`) — ONLY
   `aggregate(row)` and `entity(row)` are hand-typed today (everything
   else reads generically through Contracts' `declaration()`). If your
   construct is one of these two, add `yourfield: Array(row[:yourfield])
   .map { |held| rule(held) }` to its returned hash. **This is the step
   most likely to be silently skipped** — it produces zero test failure
   until either real corpus content exercises the field OR you run
   `spec/round_trip_spec.rb`'s "hand-typed reconstruction methods return
   every key their construct's own IR declares" test (added specifically
   to catch this — run it explicitly, see step 6).
5. **Fuzzer claim** (`lib/hecks/fuzzing/properties.rb`) — add
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
  file in-process** (`Hecks::Adapters::Prism`, if you're scripting a
  corpus migration rather than hand-editing) — use `Prism.forget(path)`/
  `Prism.forget_all`, not a bare re-`Kernel.load`.
- **`Hecks::Codemod`** (`lib/hecks/codemod.rb`) already exists
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
- **Widening a sharing scope (aggregate → its own entity tree → the whole
  chapter) makes description-only text matching dangerous, in two
  DIFFERENT ways — both bit real corpus, not hypothetically.** (1) A
  wider TEXT WINDOW can accidentally include a NESTED construct's own
  unrelated declaration under the identical description — a codemod
  scanning `ATMCard`'s own window for `given("customer is active")`
  caught its nested `Withdrawal` entity's own, differently-scoped
  declaration too, and silently rewired it wrong; fix: carve nested
  `entity ... end` blocks out of any text-window scan before matching by
  description alone. (2) At CHAPTER width specifically, the SAME
  description can legitimately mean two DIFFERENT canonicals (`Account`'s
  own `customer.status == "active"` vs. `ATMCard`'s own
  `account.customer.status == "active"` — same words, a genuinely
  different predicate, since they reach "the customer" through different
  reference chains). Never convert a candidate to a bare reference
  without independently verifying its OWN canonical text matches the
  declaration it would resolve to — a bare reference is deliberately
  trusting, not re-validating, so that verification has to happen BEFORE
  the edit, by you or a codemod's own `find_candidates`, never skipped.
  See `docs/resolution-rules/chapter-given.md`'s own "Known limitations"
  for the full real-corpus case this scoped around rather than got wrong.
- **A "hoist un-shared local declarations to one shared point" codemod's
  own safety net needs a DIFFERENT invariant than `Hecks::Codemod`'s
  default byte-identical-IR check.** That default is right for a rule
  that IMPORTS an already-existing value (round 2's append-fields) but
  WRONG for a hoist: converting N local declarations into one shared
  declaration + N references genuinely GROWS the owner's own
  `preconditions`/`invariants` list (a local, command-scoped rule was
  invisible to it before; the owner's new declaration is not) — that
  growth is the intended effect, not a regression to catch. The real
  invariant for this codemod family is narrower: every command's own
  EFFECTIVE rule set (kind/description/canonical, ignoring which
  construct's "(declared)" list it now shows up on) is unchanged.
  `bin/codemod_hoist_local_givens` is the reference implementation of
  this narrower check — copy it rather than reusing the default
  byte-identical comparison for the next hoist-shaped codemod.
- **`bin/query_ir duplicates` (`lib/hecks/query_ir.rb`'s
  `declaration_count`) needs a matching update EVERY TIME a new sharing
  scope ships**, and it can only ever be a lagging structural snapshot —
  it reads the exported IR, which by design cannot distinguish "I
  declared this myself" from "I referenced someone else's declaration"
  (the same fact `collect_rules`' own top comment already gives for why
  object identity carries no signal: `MetaValidator.call`'s
  `Assembly.call` rebuilds the whole graph fresh from flat rows, so a
  referenced rule and a locally-declared one are structurally
  indistinguishable by the time anything reads `chapter.aggregates`).
  Cross-entity sharing needed teaching it "covered by ANY `(declared)`
  entry sharing the same root aggregate," not just an exact-owner match.
  Chapter-wide sharing could NOT be taught at all — a chapter-referenced
  given write-throughs into its own aggregate's `@named_givens` exactly
  like a local declaration would, so the exported IR is genuinely
  identical either way; that gap is now a documented, permanent,
  accepted limitation, not a bug to keep chasing. Read
  `declaration_count`'s own comment before assuming a new sharing scope
  will "just work" with the existing query.
- **A round is not actually done — Ruby OR Rust — until you have
  independently re-run the thing that proves it**, not once you've read
  an agent's own report claiming it. `parser_parity_spec` is tagged
  `:io` and excluded from BOTH the default `bundle exec rspec` run AND
  the pre-push hook's own default profile — a Ruby-only round's full
  gate sweep, and even a real `git push`, can report 100% green while
  genuinely leaving Rust parity broken on `main`. This happened for
  real: a Ruby-side round's own commit message admitted "Rust mirror NOT
  YET DISPATCHED," that admission got missed, and `main` sat with 5 of
  35 `parser_parity_spec` examples failing (including the self-hosted
  meta-domain, which can independently exercise a brand-new construct in
  its OWN grammar description of itself) for real wall-clock time before
  a SIBLING round's own Rust-mirror agent hit the resulting mess and
  correctly refused to guess past it. Explicitly run `bundle exec rspec
  spec/parser_parity_spec.rb --tag io` yourself and read every line
  before calling any round — yours or a dispatched agent's — finished.
- **A Rust-mirror agent must create and work in its OWN fresh isolated
  worktree, every time, including for a "just one more thing" follow-up
  after its main commit** — never the shared main checkout, even
  briefly. Say this explicitly in the dispatch prompt; it has been
  gotten wrong twice by different agents in ways that left uncommitted,
  orphaned edits sitting in the shared checkout, blocking a completely
  unrelated sibling round's own merge. If you find such an orphan,
  `git stash` it (labeled, never discard outright) rather than guessing
  whether it's safe to lose, and read the diff before deciding whether
  to reuse or replace it.
- **Trust `git status` in an agent's own worktree over any "running" /
  "idle" status label before killing OR before assuming it's safe to
  proceed past it** — a background task tracker's own status can lag
  well behind reality in both directions: an agent showing "running"
  long after its real work already landed, or one that looks idle but
  still has genuinely live, uncommitted changes sitting in its worktree.
  `git status --short` inside that SPECIFIC worktree directory is cheap
  and ground-truth; a status label is not.
- **A commit message claiming "Merge X" is not proof it IS one.**
  `git log -1 --parents <sha>` (or `git cat-file -p <sha>` and read the
  `parent` lines) should show TWO parents for a real `--no-ff` merge; an
  agent that used `--squash` or otherwise re-committed a branch's content
  instead produces a single-parent commit with a misleading message,
  which silently breaks anything relying on branch ancestry afterward
  (`git branch --contains`, `git merge-base --is-ancestor`, `git branch
  -d`'s own "not fully merged" check — which is actually correct in this
  case, and the right signal to go verify content equality with `git
  diff <old-branch-tip> <the-commit-that-claims-to-have-merged-it>`
  before force-deleting).
