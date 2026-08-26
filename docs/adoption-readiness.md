# Adoption readiness: what a skeptical outside evaluator sees

**Audit lens.** This reads the repo the way an engineer at another company
would: a `git clone` of what's on GitHub, no Slack history, no side-channel
context, no author to ask. Every claim below was checked against the actual
repo state on this branch (`docs/adoption-readiness-audit`) — commands and
file:line citations are given so the numbers can be re-verified rather than
trusted.

---

## 1. What the public artifact says

An evaluator who clones this repo and spends twenty minutes reading would
walk away with the following facts. Each was independently verified; where a
number differs from what a casual skim (or a prior briefing) might assume,
that's flagged.

**Version.** `hecks.gemspec` requires `lib/hecks/version.rb`, which reads:

```
lib/hecks/version.rb:15   VERSION = "0.3.0"
```

Confirmed: **0.3.0**. A 0.x version on a repo this large is itself a signal —
pre-1.0, no stability promise implied by semver convention.

**Git history start date.** This branch's history is a single linear
lineage of **980 commits**. The first is:

```
13fd8faa 2026-07-25 15:42:31 -0700  Miette <miette@embryonaut.ai>
"feat: hecksagain 01 — the first vertical slice, Ruby as source of truth"
```

Confirmed: history begins **2026-07-25**. Given the last commits land around
2026-08-26 (today, per this session), that's **980 commits in roughly 32
days** — an average pace of ~30 commits/day sustained for a month. An
evaluator will notice this immediately; it reads as either a very unusual
solo effort or heavily agent-assisted throughput (see next point). Note also
that the very first commit message is literally titled **"hecksagain
01"** — a name that appears nowhere else in the public-facing docs (README,
gemspec) but is fossilized in commit `13fd8faa` and repeated in the rename
commit discussed in §2. A reader who runs `git log --reverse | head` sees
the project's working name before it became "hecks."

**Example domains.** `examples/` contains exactly four subdirectories:

```
examples/banking
examples/compliance
examples/pizzas
examples/roster
```

Confirmed: **four example domains**, matching the assumption. Each has a
real `bluebook/` folder with `.bluebook`/`.hecksagon`/`.world` files.

**Fraction of commits by an agent.** `git log --format="%an <%ae>" | sort |
uniq -c | sort -rn` gives:

```
 856  Miette <miette@embryonaut.ai>
  71  Chris Young <belleboche@gmail.com>
  45  Chris Young <chris@trusona.com>
   8  Claude <noreply@anthropic.com>
```

Total: 980. Treating `Miette` (856) and `Claude` (8) as agent-attributed
authorship: **864 / 980 = 88.2%**. This *confirms* the "~88%" figure rather
than contradicting it — computed independently, not restated.

The more interesting finding is what the repo does *not* say: nothing in
this checkout explains who or what "Miette" is. There is no `CLAUDE.md` at
the repo root, no mention in README, no CONTRIBUTING file. The only clue
anywhere in this repo is one sentence in
`docs/hecks-survey-what-we-wish-we-had.md:15` — itself an internal-audience
document (see §2) — which in passing calls Miette "a persistent agent"
belonging to a *different*, non-public project. An outside evaluator reading
`git log` will see that 87% of the codebase's authorship traces to an
identity that the repo itself never introduces, with an `@embryonaut.ai`
email domain that also goes unexplained (see §2 and §3 on Embryonaut).

**ADRs marked "Accepted — not yet implemented."** `docs/decisions/` holds
28 files, `docs/implemented/decisions/` holds 20 (48 ADRs total — the split
itself, implemented vs. not, is a real and useful convention). Grepping both
trees for the literal status string:

```
docs/decisions/0010-ruby-is-the-reference-implementation.md:3
docs/decisions/0025-the-dsl-names-one-idea-one-way-and-a-word-earns-its-place-by-being-used.md:3
docs/decisions/0026-the-language-uses-everything-it-declares-and-what-it-does-not-use-is-a-sub-language.md:3
```

Confirmed: **three** ADRs are marked "Accepted — not yet implemented,"
matching the assumption. One of the three is worth flagging on its own
merits: **ADR 0010, "Ruby is the reference implementation; other runtimes
validate against it, continuously,"** is the ADR that establishes the exact
differential-testing discipline (`spec/rust_conformance_spec.rb`,
`spec/codegen_parity_spec.rb`, `spec/parser_parity_spec.rb`) that the README
("Runtimes" section) and `.githooks/pre-push` both describe as live,
running, load-bearing infrastructure *today*. Its own decision record still
says "not yet implemented." That's an ADR-hygiene gap, not a real gap in the
mechanism — but a skeptical reader who checks the decision log to see
whether the Rust-parity claim is trustworthy will find its governing ADR
apparently disagreeing with the README. Listed again in the defects section
below.

**A finding beyond the prompt's checklist, worth surfacing here because it
belongs in "what the public artifact says":** `deploy/` is tracked in git
and contains generated SAM deploy targets for five names, not two:
`banking`, `pizzas` (the public examples), and **`embryonaut`,
`lifeadelics`, `lifeadelics-demo`** — three names that correspond to nothing
in `examples/`. `deploy/embryonaut/{Makefile,bastion.yaml,samconfig.toml,
template.yaml}` are real, checked-in, generated deployment artifacts (region
`us-east-1`, live Lambda config) for a domain the repo never defines
publicly. This is the single most concrete piece of evidence in the repo
that hecks is not just a language demo — something real is deployed with
it — and it sits there completely unglossed. (No secrets are exposed; the
`.world`-driven "no secret typed anywhere" design holds up on inspection.
This is a transparency/narrative gap, not a security one.)

---

## 2. The gap between that and reality

`docs/hecks-survey-what-we-wish-we-had.md` is the one document in this repo
that contains the real backstory, and it is unambiguous once you know to
look for it:

> "hecks is a sprawling *organism* — a persistent agent ('Miette') with a
> modelled body, daemons, hooks, a corpus of ~156 bluebooks describing its
> own machinery. hecks is the clean *core* that organism now runs on."
> (line 17-18)
>
> "A thorough read of `~/Projects/hecks` (the older, larger sibling that now
> depends on hecks via its Gemfile)..." (lines 3-4)

So the document itself confirms the shape the task described: this repo is
the extracted, cleaned core; a larger predecessor project depends on it via
a Gemfile; that predecessor is where "Miette," the daemons, and the
Storehouse tooling actually live, in a **private fork**
(`hecks-hecksagain`, named explicitly at line 27). None of this is stated
anywhere a newcomer would naturally look — README, gemspec description, or
CONTRIBUTING (which doesn't exist).

**A second, more subtle problem with this document as the newcomer's
on-ramp:** it is internally confusing about which project is which, and the
git timeline explains why. The doc's own commit
(`757f0d59`, 2026-08-23 12:05:42) landed *the same day*, a few hours before,
the repo-wide rename commit `db1a406a` ("Rename Hecksagain:: to Hecks::
throughout (module, gemspec, paths)", 2026-08-23 22:17:17). At the moment
this survey was written, "hecks" unambiguously meant the *older* organism
project and "our gem" meant what was still internally called Hecksagain.
Hours later, the rename collapsed that distinction — this repository is now
*also* called "hecks" (`hecks.gemspec:6`, `module Hecks`). Read today, from
inside this checkout, sentences like "a thorough read of `~/Projects/hecks`"
and "*what does it have that we wish we had*" name the wrong project by the
same name this repo now answers to. A newcomer has no way to resolve that
confusion from the doc alone; it needs either an editor's note or to be
retired in favor of the excerpt recommended below.

**What a newcomer needs to know, and where it should live:**

1. **That hecks is an extracted core, not the whole story.** Belongs in
   **README.md**, as a short section — a good placement is right after the
   opening paragraph (before "Quickstart"), or as a final "Provenance"
   section near "Verify" at the bottom so it doesn't crowd the technical
   pitch. Two or three sentences: hecks began as the core of a larger,
   organism-style project; that project was extracted down to this clean
   surface and now depends on hecks as a gem; the extraction is why the
   corpus, ADR log, and tooling are shaped the way they are (self-hosted
   grammar, differential Rust harness, generated-everything philosophy).

2. **That it runs in production today, and where.** Belongs in the same
   README section, one sentence, plus a pointer to `deploy/` if the
   maintainer is comfortable naming Embryonaut publicly (it's already
   discoverable from `deploy/embryonaut/` and the `.world` example on
   README line 356 — hiding it in prose while it's visible in the tree
   is worse than naming it). If the maintainer is *not* comfortable naming
   the company, then `deploy/embryonaut/`, `deploy/lifeadelics*/`, and the
   `owner "Embryonaut"` comment in the README's own Banking `.world`
   example (line 356) need to be scrubbed or genericized — right now the
   repo half-discloses this by accident, which is the worst of both
   options.

3. **Who/what "Miette" is, and why 88% of commits carry that authorship.**
   This is a **CONTRIBUTING.md** (currently absent) concern more than a
   README concern — a "How this project is built" section stating plainly
   that most commits are produced by an AI coding agent under human
   direction/review, with a one-line description of the workflow (or a
   pointer to wherever that's documented for the maintainer's own
   purposes). Leaving `git log` as the only source of this fact makes an
   evaluator dig for something the project has no reason to hide.

4. **That Storehouse — the thing the repo's own survey doc says is the
   single biggest gap — exists and lives in a private fork.** This belongs
   in a **new docs file**, e.g. `docs/roadmap.md` or `docs/known-gaps.md`,
   because it's forward-looking project information, not decision history
   (ADRs) and not a guide (docs/implemented/guides/). It should be a public,
   condensed version of the ranked list already in
   `docs/hecks-survey-what-we-wish-we-had.md` §"What we wish we had," with
   the internal-only material (private fork paths, `~/Projects/hecks`
   references, inbox card IDs) stripped. See §3 below — this is also where
   README's honesty gap and this recommendation meet.

5. **The survey document's own audience mismatch.** Either add a one-line
   editor's note at the top of `docs/hecks-survey-what-we-wish-we-had.md`
   ("written 2026-08-17 for internal use, before the Hecksagain→Hecks
   rename; 'hecks' below refers to the predecessor organism project, not
   this repository") or move its externally-relevant content into the new
   `docs/roadmap.md` from item 4 and demote this file to an explicitly
   internal/historical folder. Right now it's the single richest source of
   truth in the repo and also the most likely to actively mislead a
   newcomer who doesn't already know the history.

---

## 3. Scope honesty

`docs/hecks-survey-what-we-wish-we-had.md`'s ranked list ("What we wish we
had — Storehouse, ranked") does exactly what the task predicted:

- **#1** is "One universal MCP door, plus three zoom levels of discovery"
  (line 52) — the document states hecks's own equivalent is "a 3-tool
  query-IR MCP (`bin/hecks_query_ir_mcp`); the only agent-facing dispatch is
  `bin/run`" and calls Storehouse's version "**Real and running over
  there**" (lines 67-70).
- **#2** is "`storehouse follow` — a live tail of every dispatch, every
  process" (line 71), contrasted with "`bin/history` dumps a journal after
  the fact; nothing live, nothing cross-process" (lines 85-86), marked
  "**Real, verified streaming**."

Both are confirmed exactly as described. The document is also explicit,
twice, that Storehouse lives outside this repo:

> "A Rust binary (`~/.local/bin/storehouse`, source in the private
> `hecks-hecksagain` fork)." (line 27)

and the closing "Sources" section lists only paths under the sibling
project (`~/Projects/hecks`, `tooling/storehouse-mcp/`, `hecks_runtime/`) —
none of which exist in this repository (confirmed: no `hecks_conception/`,
`hecks_runtime/`, or `tooling/` directory anywhere in this checkout).

**Does the README state plainly what is and isn't in this public repo?**
No. `README.md` contains zero occurrences of "Storehouse," "predecessor,"
"organism," or "Embryonaut" as prose (the one "Embryonaut" string is an
example value in a `.world` code sample, not an explanation — line 356).
The README's "Runtimes," "Machine-readable IR," and tool table read as a
complete inventory of what an agent can do with hecks; nothing signals that
a materially more capable dispatch/observability layer exists and isn't
here. An adopter evaluating "can I drive this whole system through one
door, live" would have to discover the gap themselves — the honest answer,
per the project's own internal survey, is "not yet, and the reference
implementation of that idea is in a private fork."

**Recommended README language.** Add a short, plainly-worded section —
suggested placement: immediately before "## Runtimes" or as the last
subsection of "## The tools" — along these lines:

> ### What's in this repo, and what isn't
>
> This repo is the complete language, runtime, and Rust dispatch parity
> harness. It does **not** include: a universal MCP dispatch door with live
> discovery (`bin/hecks_query_ir_mcp` is a 3-tool read-only IR query
> server, not a dispatch door); a live tail of dispatches across processes
> (`bin/history` is after-the-fact only); inbound scheduling/clocks
> (`driving on interval | cron | clock` is conceived, not built — see
> [ADR-00xx] or `docs/roadmap.md`); or middleware-as-declared-records
> (`gated_by`/Gate). These are real, ranked gaps, tracked in
> `docs/roadmap.md`, not aspirational features implied to exist.

This turns an implicit, discoverable-only-by-digging gap into an explicit,
credible statement — which reads as *more* trustworthy to a skeptical
evaluator than silence, not less.

---

## 4. Prioritized punch list

Ordered highest-leverage-first. "Leverage" here means: cheapest to fix,
biggest reduction in the chance a serious evaluator walks away either
confused or feeling misled.

1. **Add a "Provenance" / "What's in this repo" section to `README.md`.**
   (S, 1-2 hours.) Covers §2 items 1-2 and §3's recommended language in one
   editing pass. Files: `README.md` only. Highest leverage because it's the
   one file every evaluator reads first, and the fix is pure writing, no
   design work.

2. **Add a one-line editor's note to the top of
   `docs/hecks-survey-what-we-wish-we-had.md`** clarifying it predates the
   Hecksagain→Hecks rename and "hecks" in its body means the *other*
   project. (S, 15 minutes.) File:
   `docs/hecks-survey-what-we-wish-we-had.md`. Cheap and prevents active
   confusion for anyone who finds this file (it's linked from nowhere in
   README today, but it's discoverable via `docs/` directory listing or
   grep, and it's the single richest — and most misleading-without-context
   — document in the repo).

3. **Create `docs/roadmap.md`** with the public-safe version of the ranked
   gap list (universal MCP door, `follow`+SourceTag, Drivers — the "If we
   build three" section, lines 259-268, is already close to publishable
   as-is). (M, half a day.) Files: new `docs/roadmap.md`; link it from
   README's new section (item 1) and from the tool-table entry for
   `bin/hecks_mcp_door`, which already self-references
   `docs/hecks-survey-what-we-wish-we-had.md` by name in its own `--help`
   text (README line 554) — that reference currently points evaluators at
   an internal document with no framing.

4. **Add a `CONTRIBUTING.md`** with a short "How this project is built"
   section naming the agent-driven workflow plainly. (S, 1-2 hours.) New
   file: `CONTRIBUTING.md`. Directly answers the question a `git log`
   skim provokes before the evaluator has to ask it.

5. **Fix ADR 0010's status line.** (S, 15 minutes — but out of scope for
   this pass per instructions; recommending only.) File:
   `docs/decisions/0010-ruby-is-the-reference-implementation.md:3`. Change
   "Accepted — not yet implemented" to reflect that the differential
   harness it describes is live (`spec/rust_conformance_spec.rb`,
   `.githooks/pre-push`). Low effort, removes a real internal
   inconsistency between the decision log and the README.

6. **Resolve the ADR 0029 filename collision** (see defects below — two
   different decisions share number 0029). (S, 15 minutes to renumber one
   — out of scope for this pass, recommending only.) Files:
   `docs/decisions/0029-rust-reads-and-writes-any-era-ruby-mints.md` and
   `docs/decisions/0029-identity-is-a-value-concept-and-relationships-state-cardinality.md`.
   Cosmetic but exactly the kind of small inconsistency a skeptical
   reviewer treats as a proxy for overall care.

7. **Decide, deliberately, what to do with `deploy/embryonaut/` and
   `deploy/lifeadelics*/`.** (M, needs a product decision, not just an
   edit.) Either name and own it in the new README section (item 1) or
   remove/genericize the tracked deploy configs. Currently the repo
   half-discloses real customer names by accident, which is worse than
   either alternative.

8. **Address the parser-parity corpus accounting gap** (see defects below —
   `lib/hecks/framework/bluebook/compliance.bluebook` is silently
   unverified due to a stem collision with `examples/compliance`, and the
   spec's own safety-net check doesn't catch it). (S-M, a few hours —
   flagged for the maintainer; out of scope to fix in this pass.) File:
   `spec/parser_parity_spec.rb`. Lower priority than items 1-7 for an
   *adoption* audit specifically (it's an internal test-suite integrity
   issue, not something an evaluator would notice), but high-value to fix
   because the whole point of that spec's self-accounting tests is to make
   this class of gap impossible.

---

## Factual defects found

Audit only — nothing below was fixed, per instructions.

### 1. Two ADRs both numbered 0029 — CONFIRMED

```
docs/decisions/0029-rust-reads-and-writes-any-era-ruby-mints.md
docs/decisions/0029-identity-is-a-value-concept-and-relationships-state-cardinality.md
```

Both exist, both under `docs/decisions/`, both numbered 0029. Unrelated
topics (Rust era I/O vs. identity/relationship modeling). Confirmed by
directory listing and by `find . -iname "*0029*"`.

### 2. `.githooks/pre-push`'s citation of `docs/implemented/rust-experiment.md` — CONFIRMED, but the reverse of what might be assumed

The task description anticipated finding the hook citing a stale
conclusion. What's actually there is more interesting: **the hook has
already been patched to account for the reversal**, and it's the *source
document's own banner* whose claim about the hook is now out of date.

- `.githooks/pre-push:6-11` reads: "...That FIRST comparison mechanism is
  retired for good (docs/implemented/rust-experiment.md is itself a
  historical record now — read its own top banner before citing it as
  current) — but Rust was restarted days later and is very much alive,
  deployed live, with its own real differential harness
  (spec/rust_conformance_spec.rb, spec/codegen_parity_spec.rb,
  spec/parser_parity_spec.rb)."

- `docs/implemented/rust-experiment.md:3-17` is a "REVERSED, 2026-08-07"
  banner explaining that the document's own "retire Rust" conclusion did
  not hold. Line 9-10 of that banner says: "`.githooks/pre-push`'s own
  header comment still cites this document as if the retirement held — it
  doesn't; there is a second, real runtime now..."

So: the banner's claim about `pre-push` is itself stale — `pre-push`
already says exactly what the banner insists it should say. Both files are
internally correct about the underlying fact (Rust was restarted and is
live); the discrepancy is that `rust-experiment.md`'s own self-correction
note has not been updated to reflect that `pre-push` was *also* already
fixed. This is a small, second-order documentation drift rather than the
first-order "hook cites a dead conclusion as current" bug the audit brief
described — worth noting precisely because it shows the same class of
drift (a correction note outliving its own correctness) recurring even in
the file that exists specifically to correct drift.

### 3. Truncated `ArgumentGate` error string — PARTIALLY CONFIRMED / LIKELY ALREADY FIXED, spec comment appears stale

- The truncated string and its own explanation live at
  `lib/hecks/runtime/command_interpreter/argument_gate.rb:84-99`, in a
  comment documenting a **historical** bug: `Freeze does not declare
  standing — it takes ` (trailing off with nothing after "it takes")
  because `declared_reading` rendered `{declared}` empty for a command
  with zero attributes. The comment states the fix explicitly: "Only the
  empty case changes" — and the current code
  (`argument_gate.rb:96-99`) is:

  ```ruby
  def declared_reading(command)
    declared = command.attributes.map(&:name)
    declared.empty? ? "none" : declared.join(", ")
  end
  ```

  i.e., it now renders `"none"` rather than an empty string, for *every*
  caller of `declared_reading` (both `refuse_unknown_arguments` and
  `refuse_absent_arguments`). `git log -S'declared.empty? ? "none"'` dates
  this fix to commit `4e6d91e` (2026-08-14).

- `spec/rust_conformance_spec.rb:106-108` documents, in present tense, a
  known Ruby/Rust mismatch where "Ruby's `ArgumentGate` reaches an
  (already-broken, pre-existing, unrelated-to-Rust) truncated 'does not
  declare standing — it takes ' message." This comment (and the
  `known_reaction_gap?` matcher at lines 122-125 it explains) was added in
  commit `c727cfa9` (2026-08-11) — **three days before** the `declared_reading`
  fix above landed.

- `spec/runtime/freeze_accounts_on_suspension_spec.rb:86-89` independently
  confirms the general shape of this bug was fixed (past tense: "THE
  REFUSAL THIS USED TO ASSERT... refused every row with `does not declare
  standing`"), via a `with: { account: :account }` projection that stops
  the offending payload from reaching `FreezeAccount` at all in the
  ordinary case. Running this spec directly (`bundle exec rspec
  spec/runtime/freeze_accounts_on_suspension_spec.rb`) passes, 0 failures.

**Assessment:** the truncation mechanism itself (`declared_reading`
returning an empty string) was fixed on 2026-08-14, after
`spec/rust_conformance_spec.rb`'s comment describing it as current was
written on 2026-08-11. The spec's comment quotes the literal string "— it
takes " with nothing following; given the current code, the same scenario
would now render "— it takes none" instead. The comment was not
re-verified against the fix. The underlying Ruby/Rust *wording* mismatch
this test exists to paper over may still be real (Ruby would now say "...it
takes none," Rust reaches a different message, "no identity found" per
line 108-109) — so `known_reaction_gap?` may still be doing real, necessary
work — but the specific truncated string quoted in the comment is very
likely no longer what Ruby produces. I could not fully execute the
Rust-side comparison in this environment (no Rust toolchain build attempted,
to avoid mutating repo state or requiring a long build); this is reported as
a high-confidence static finding, not a verified runtime reproduction.
Recommend the maintainer re-run `spec/rust_conformance_spec.rb` and update
or remove the stale wording in the comment.

### 4. `spec/parser_parity_spec.rb` corpus accounting — CONFIRMED discrepancies, plus one newly-found real gap

Counted directly (via the spec's own `Dir.glob` logic, executed read-only):

- `PARITY_EXAMPLE_ROOTS`: 4 (`banking`, `compliance`, `pizzas`, `roster`)
- `PARITY_GRAMMAR_CHAPTERS`: 2 (`expression`, `translation`)
- `PARITY_FRAMEWORK_MEMBERS`: 4 (`compliance`, `console_settings`,
  `governance`, `identity`)
- `PARITY_FIXTURE_MEMBERS` (`spec/fixtures/**/*.bluebook`): **23** files
  today, not the "twenty" the comment at `spec/parser_parity_spec.rb:166`
  cites ("All twenty fixtures round-tripped byte-exact..."). This is
  functionally harmless — the merge that adds fixtures to
  `REAL_PARITY_MEMBERS` (lines 266-277) is a live `Dir.glob`, so new
  fixtures are automatically covered — but the comment's count is stale
  history, not a live invariant.
- Total `PARITY_CORPUS_MEMBERS` entries: **34**, but only **33 unique
  stems** — because `examples/compliance` (an example domain) and
  `lib/hecks/framework/bluebook/compliance.bluebook` (a framework member)
  both produce the stem `"compliance"`.

**This collision is a real, previously-undocumented gap, not just a
cosmetic duplicate.** `REAL_PARITY_MEMBERS` is a `Hash`, so its
`"compliance"` key resolves only to the `examples/compliance` domain
(`spec/parser_parity_spec.rb:227-233`) — the framework file
`lib/hecks/framework/bluebook/compliance.bluebook` is never fed to
`hecks-parse` by any `REAL_PARITY_MEMBERS` entry. It is also not
listed in `PENDING_MEMBERS`, because the exclusion list at
`spec/parser_parity_spec.rb:202` already contains the string
`"compliance"` and `Array#-` removes *every* matching element, not one per
occurrence — so both the real `examples/compliance` stem entry and the
phantom framework-file stem entry get silently subtracted out together.
The result: the spec's own safety-net test, "accounts for every real corpus
member — nothing silently skipped" (`spec/parser_parity_spec.rb:371-376`,
`unaccounted = PARITY_CORPUS_MEMBERS.map(&:first) - PENDING_MEMBERS.keys -
REAL_PARITY_MEMBERS.keys`), passes cleanly despite
`lib/hecks/framework/bluebook/compliance.bluebook` being completely
untested by this harness — exactly the class of gap that check exists to
catch. Verified by direct enumeration (executed the spec's own glob/stem
logic in an isolated `ruby -Ilib` invocation, no domain boot, no writes):
34 total entries tally to 33 unique stems, with `"compliance"` the sole
stem appearing twice.

**Net figures for the corpus-parity question as asked:** of the 33 unique
corpus stems this spec recognizes, PENDING_MEMBERS is empty (by design,
"Stage 6" per the comment at line 182) and all 33 nominally have a real
byte-match assertion — but one of those 33 ("compliance") is silently
backed by only one of its two underlying files, so the true count of
distinctly-verified `.bluebook` files achieving real parity is **32
files representing 33 corpus stems, with a 34th file
(`lib/hecks/framework/bluebook/compliance.bluebook`) never exercised and
never flagged.** Separately, the repository as a whole contains 82
`.bluebook` files (`find . -iname "*.bluebook"`, excluding
`.claude/worktrees/` and `deploy/`); the parity spec's corpus (34 entries)
is a deliberate subset of that — grammar-internals files under
`rust/parser/tests/fixtures/` and `lib/hecks/language/` are exercised by
other specs, not this one, and were not expected to appear here.

### Additional defects found during the audit (beyond the four listed)

- **ADR 0010's status line is stale relative to the repo it governs.**
  `docs/decisions/0010-ruby-is-the-reference-implementation.md:3` reads
  "Accepted — not yet implemented," but the differential-harness mechanism
  it decides on is described as live, running infrastructure in both
  `README.md`'s "Runtimes" section and `.githooks/pre-push:11-21`
  (`spec/rust_conformance_spec.rb`, `spec/codegen_parity_spec.rb`,
  `spec/parser_parity_spec.rb` all cited there as real gates). Already
  listed in §1 and the punch list; repeated here because it's a genuine
  factual inconsistency, not just a narrative gap.

- **`deploy/` tracks real, named non-example deploy targets** —
  `embryonaut`, `lifeadelics`, `lifeadelics-demo` — alongside the two
  public examples (`banking`, `pizzas`). Confirmed via `git ls-files
  deploy/*/` (3-4 tracked files per directory: `Makefile`,
  `samconfig.toml`, `template.yaml`, and `bastion.yaml` where present). No
  secrets found on inspection (region strings and Lambda config only), but
  the repo is silently disclosing customer/product names it never explains
  anywhere in prose. Already covered in §1 and the punch list.

---

*Scope note: this document is the only file added or modified in this
audit pass. `lib/`, `spec/`, `README.md`, and all ADRs were read but not
touched.*
