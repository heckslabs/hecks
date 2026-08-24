# Extending Hecks

This one is not about writing a domain, and it is not about writing an
adapter. It is about the day you need a word the DSL does not have yet
— a new keyword, a new argument, a new closed vocabulary term — and you
have to ship it without breaking every `.bluebook` file that already
boots today. That is a different kind of change from the ones the
other guides cover, and it has its own discipline: the language is not
exempt from the rule it enforces on everyone else. It is data too, and
it gets checked the same way.

## The language describes itself

Every other `.bluebook` in this repository declares a business domain
— pizzas, an orchard, a bank. `lib/hecks/language/bluebook/*.bluebook`
declares something else: the language itself. `Syntax` says how a
bluebook is spelled — every word the surface admits, the body it may
open, the argument it takes. `Vocabulary` says what the closed sets are
— comparison operators, mutation ops, primitive types. Both are written
in the same DSL, loaded by the same `Kernel.load`, judged by the same
`MetaValidator` that judges yours. There is no second, privileged
mechanism that defines the language from outside it — the query and
model-check machinery that verifies a user's domain is the same
machinery that verifies the language's own definition, applied to
itself.

That has one direct consequence for you: **a new word is a declared
row before it is a line of Ruby.** You start in the concept file that
owns the word: Aggregate spellings live in `aggregate.bluebook`, Command
spellings in `command.bluebook`, World spellings in `world/world.bluebook`,
and so on. Each aggregate carries local `KeywordSeed` and `ArgumentSeed`
value objects. `SyntaxBoot` discovers and combines them; there is no central
syntax catalog or filename list to update.

```ruby
Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook").aggregates.map(&:hecks_name).sort
# => ["Aggregate", "Bluebook", "Command", "Dispatch", "Entity", "Handler", "Member", "Policy", "ProcessManager", "Query", "ReadModel", "Syntax", "ValueObject", "Vocabulary"]
```

`Syntax` sits in that list next to `Command` and `Query` — an aggregate
like any other, judged the same way. It owns the live `Keyword` and
`Argument` records and their lifecycle; their static source rows remain
with the aggregates whose language they describe. The combined rows are what
`bin/reference` projects into `docs/implemented/reference/*.md` — the prose you
read when you look up what `given` takes came out of exactly this
table, which is one more reason the row has to be right before
anything else follows from it.

## A word's life

Every row in `Syntax::Keyword` and `Syntax::Argument` carries a
`status`, and the set is closed and small:

```ruby skip
proposed → admitted → deprecated → retired
```

A row defaults to `admitted` — spelling `status: "admitted"` on every
one of the surface's rows would bury the table in ceremony, so only a
word actually entering or leaving the language spells its status at
all. `proposed` means declared and not yet real: no builder answers it
yet, and nothing projected from the language can see it. `admitted`
means live. `deprecated` means still read, on its way out. `retired`
means gone — the row stays, as history, but no builder may answer it
any more. There's a fifth thing a row can say, in its own column
rather than its own status: `was:`, the rename column. `sets` carries
`was: "sets"` right now — the corpus itself, still full of
`sets`, is the proof that a rename never stops the old spelling
from booting.

The two value-object shapes are deliberately repeated beside each owning
aggregate:

```ruby skip
Keyword  — word, context, body, inner, opens, fills, status, was
Argument — keyword, context, at, named, kind, required, fills,
           selects, pair_key_fills, pair_value_fills, pairs_shape, status
```

A `Keyword` row says where a word may be typed (`context`), what its
block is if it has one (`body`: none / keywords / source / rows), what
context that block reads in (`inner`), what category of record it
opens (`opens`), and what field of the enclosing record it fills
(`fills`). An `Argument` row says, per keyword, what each position or
named argument looks like when typed (`kind`: text / symbol / number /
flag / literal / constant / pairs / list), whether it's required, and
which field it lands on. One row per `(word, context, form)` — a word
admitting two shapes gets two rows, not one row with a maybe.

## `bin/evolve`: the stations

Adding a word by hand — editing the row, teaching the builder, moving
the golden IR, remembering which specs gate the change — is a many-file
walk that used to live in memory and review alone. `bin/evolve` makes
it mechanical. Read its header comment before you touch anything; this
is what it actually does, station by station:

```ruby skip
bin/evolve status
bin/evolve propose <word> --context Aggregate [--body ...] [--inner ...] [--opens ...] [--fills ...]
bin/evolve admit <word> --context Aggregate
bin/evolve deprecate <word> --context Aggregate
bin/evolve retire <word> --context Aggregate
bin/evolve rename <word> --context Aggregate --to <new-word>

bin/evolve argument-propose <keyword> --context X --kind K [--at N] [--named NAME] [--required true|false] [--fills F]
bin/evolve argument-admit <keyword> --context X [--at N] [--named NAME]
bin/evolve argument-deprecate <keyword> --context X [--at N] [--named NAME]
bin/evolve argument-retire <keyword> --context X [--at N] [--named NAME]
```

`status` prints where every word stands: how many rows are not simply
`admitted`, and which ones carry a `was:`. Run it before you start —
it's the fastest way to see whether the word you want already exists
under another spelling.

Every *mutating* command — `propose`, `admit`, `deprecate`, `retire`,
`rename`, and their `argument-*` siblings — runs the identical dance,
implemented once as `guarded` in `bin/evolve` itself:

1. **Snapshot** every discovered aggregate-local syntax source plus the
   golden `spec/golden/ir/Bluebook.json`, byte for byte, in memory.
2. **Rewrite the row** — text surgery on its owning concept file, not a
   round-trip through the IR, because the table's comments and grouping
   are part of the declaration and a round-trip would flatten both.
3. **Regenerate what the row feeds** — `GOLDEN=rewrite bundle exec
   rspec spec/ir_golden_spec.rb`, so the golden IR reflects the new
   syntax table before anything is judged against it.
4. **Run the gates** — `spec/syntax_conformance_spec.rb`,
   `spec/syntax_lifecycle_spec.rb`, `spec/ir_golden_spec.rb`.
5. **Green**: the change stands, the regenerated projections and the
   golden are left in the tree, and the tool prints what remains by
   hand — a proposed word still needs its builder before `admit` will
   hold; a rename still needs the builder to alias the new spelling to
   the old one and an identical-IR example in `spec/dsl_spec.rb`.
6. **Red**: every touched file is restored to its snapshot, byte for
   byte. Nothing was changed. The failures print as the checklist they
   are.

The tool never leaves a tree the suite has not accepted — that's the
whole point of doing the snapshot/restore in Ruby instead of trusting
you to `git checkout` cleanly if something goes wrong halfway through.
`propose` alone is intentionally inert: a proposed word reaches no
projection (`syntax_conformance_spec`'s lifecycle gates check this both
ways — a proposed row whose builder already answers it should have been
admitted, and a retired row whose builder still answers it never really
left), so you can land the row, commit it, and write the builder in a
second, separate step without the language lying about what's live in
between.

## The conformance-gate pattern

None of this would mean anything if the table and the builders could
just disagree. That's the failure mode the conformance specs exist to
close, and — because you're about to add a row to one of these tables
— it's worth understanding the pattern well enough to extend it, not
just trust it.

**`spec/syntax_conformance_spec.rb`** holds `Syntax::Keyword` and
`Syntax::Argument` to the live DSL builders, in both directions. One
direction: every word a context declares, its builder must actually
answer (`declares only words the builder answers`). The other,
separately: every word a builder answers, the table must declare
(`declares every word #{builder} answers`) — this is the direction
that matters most for you, because it's the one that catches a builder
method added without its row, the exact shape of drift that made the
old hand-written parser unprojectable in the first place. It goes
further than presence — argument *signatures* have to agree too (every
keyword argument a builder's method takes must have a row, and vice
versa), and one direction is checked asymmetrically on purpose: a
builder may demand an argument the table calls optional-adjacent in
neither direction lightly, but a table may never call an argument
optional that the builder's method signature requires — that combination
is a bluebook that parses everywhere and loads nowhere.

**`spec/vocabulary_conformance_spec.rb`** is the same shape applied to
closed sets instead of keywords: comparison operators, mutation ops,
primitive types, sign tests, dispatch order, and a few more — each one
a `Vocabulary` value object on one side and a live Ruby constant or
table on the other (`Evaluator::COMPARISONS`, `CommandRules::MUTATION_OPS`,
`IR::Attribute::PRIMITIVES`...). Some of these go past name-equality
into checking the *semantics* stay aligned — `Comparison` declares, per
symbol, which primitive it reads and whether the result is negated, and
that's held equal to what `Evaluator::OPERATORS` actually computes with,
not just which symbols exist.

**`spec/translation_vocabulary_conformance_spec.rb`** is the newest of
the three, the smallest, and the best one to read start to finish if
you ever have to build a fourth — it's a template with all the
scaffolding stripped away. The situation: the translation chapter
declares a closed set of rule kinds (`Rule.Kind` — compute, convert,
drop, move, rename, retype, retired), and `TranslationAggregateBuilder`
re-spelled the identical list by hand in its `method_missing` refusal
message. Nothing held the two together. This is what the four examples
in that file do, in order:

1. **Prove the declared side is real** — the set is genuinely closed
   (`closed_set?`) and non-empty. Cheap, and it's what stops the whole
   file from passing vacuously against an empty table.
2. **Read the live side by introspection, not by hand-copied list** —
   `TranslationAggregateBuilder.public_instance_methods(false)`, minus
   the two bits of bookkeeping (`build`, `method_missing`) that are not
   themselves rule kinds. Then assert the declared set equals that,
   minus the one entry that belongs elsewhere (next point).
3. **Name the exception, don't hide it** — `retired` is real, but it
   lives on the sibling `TranslationBuilder` (the edge, not the rule),
   so it gets its own example rather than silently falling out of the
   main comparison.
4. **Hold even the error text to the declaration** — the refusal
   message `method_missing` raises is parsed back out and checked to
   name the same set. So the two places this project could say "here
   is the list of rule kinds" — a comment-turned-error-string, and the
   language's own declaration — cannot drift from each other either.

```ruby
(Hecks::Bluebook::DSL::TranslationAggregateBuilder.public_instance_methods(false) - [:build, :method_missing]).sort
# => [:compute, :convert, :drop, :move, :rename, :retype, :unresolved]
```

That's the recipe if you ever have to write a fifth gate: find the two
places that are supposed to agree and currently have nothing enforcing
it; read the declared side off the judged meta-domain
(`MetaValidator.grammar_registry`); read the live side by introspecting
the real Ruby construct rather than retyping a list; assert both
directions; and if there's a genuine exception, name it as its own
example instead of quietly excluding it from the comparison. The lesson
underneath all three files is the same one, stated once in
`vocabulary_conformance_spec`'s own header: *a declaration nothing
reads cannot disagree with anything.* Every closed vocabulary in this
language needs a live reader holding it to the truth, or it is
decoration wearing the shape of a rule.

## The golden IR discipline

`bin/evolve` regenerates `spec/golden/ir/Bluebook.json` for you as part
of every mutating command, but it's worth knowing what that file is and
when touching it by hand is legitimate. `Bluebook#to_h` is the wire
format two production mechanisms stand on directly — era projection
mints hashes from it, and `MetaValidator` hashes it as a verdict-cache
key — so `spec/ir_golden_spec.rb` pins today's emission against a
frozen reference file rather than comparing two things both computed
fresh at test time, which would let an emission bug on an unexercised
path pass vacuously against itself.

`GOLDEN=rewrite bundle exec rspec spec/ir_golden_spec.rb` is how you
update it, and the spec's own header says exactly when that's
legitimate versus a sign something broke: **a rewrite is a claim that
the wire format changed.** Read the diff before trusting it, because
every era a domain has ever held was minted off the *old* shape — a
rewrite that quietly drops or renames a key is not a formatting change,
it's a claim that every stored era's projection needs to be re-derived.
`bin/evolve` runs the rewrite for you precisely because adding a word
changes the owning aggregate's emitted seed rows, which is exactly the kind
of change the golden file is supposed to catch — the tool trusts the
gate, not the other way around. (What happens when a *domain's own
data* has to survive a shape change, rather than the language's wire
format, is [schema-evolution.md](schema-evolution.md)'s whole subject — a sibling discipline,
same reflex: review the diff before you believe it.)

## Teaching the model checker a new finding

Sometimes the thing you're adding to the language isn't a new word but
a new *check* — a way for `bin/model_check` to catch something a
lifecycle or a process manager could declare and get wrong. This is
static analysis over the IR (no bluebook boots twice, nothing here
touches a runtime), so it lives entirely in
`lib/hecks/bluebook/model_check.rb`, and the shape is the same for
every finding it already reports. Walk one real one end to end —
`dead_transition`, from `lifecycle_findings`:

```ruby skip
lifecycle.transitions.each do |command, transition|
  next unless transition.constrained?
  next if Array(transition.from).any? { |source| reached.include?(source) }

  findings << Finding.new(kind: :dead_transition, severity: :error, subject: subject,
                           message: "#{command} from #{Array(transition.from).inspect} can never fire — " \
                                    "none of those states is ever reached")
end
```

Three pieces, and every finding in the file has the same three:

- **A check function** — here, a loop inside `lifecycle_findings` over
  every declared transition, computing `reached` (the least fixpoint of
  states the lifecycle can actually arrive at from its default) and
  flagging any transition whose `from:` is never among them.
- **The `Finding` struct** — `kind`, `severity` (`:error` or
  `:warning`), `subject` (the aggregate, entity, saga, or policy name),
  `message` (plain prose, no template the reader has to decode).
- **Wiring into the runner** — `lifecycle_findings` is called from
  `ModelCheck.call` for every aggregate and every entity, and its
  return value is concatenated into the one flat list `call` returns.

Above the check itself sits the part that actually keeps this honest:
`ALLOWED_FINDINGS`, a hand-maintained table of `[kind, subject]` pairs
that are real, understood, and not worth fixing (right now, exactly
one — an unreachable saga state in the banking example, with a comment
explaining precisely why the real domain activity is fine even though
the saga's own bookkeeping never closes). `spec/model_check_spec.rb`
enforces this table in **both directions** over the whole corpus: an
error the checker reports that the table doesn't name is a regression
you have to fix or explicitly allow; an entry in the table the checker
no longer reports is stale and must be deleted. `bin/model_check`
reads the exact same `ALLOWED_FINDINGS` constant the spec does — one
table, never a copy — so the tool a human runs and the gate CI runs
can't drift apart the way the syntax table and the old hand-written
parser once did.

If you're adding a genuinely new finding kind — say, hypothetically, a
check that a process manager's `correlates_by` field is never actually
readable off any event it handles — the mechanical steps are: write the
check function in the right section (lifecycle / saga / policy, or a
new section if it's none of those), have it return `Finding.new(kind:
:your_new_kind, ...)`, fold its results into the `*_findings` method
that already covers its construct (or into `call` directly, for
something new), add a fixture under `spec/fixtures/model_check/` that
deliberately trips it, assert the new kind in `spec/model_check_spec.rb`,
then run `bin/model_check` over the real corpus — anything it newly
flags there has to be fixed in the example domain or added to
`ALLOWED_FINDINGS` with the same kind of comment the existing entry
carries, naming exactly what's real and what's a bookkeeping gap.

## The reference coverage gate

There is one more gate, and it's the newest thing in this arc: a word
can be proposed, admitted, wired into its builder, green on every
conformance spec above, and the suite will *still* refuse the tree if
nobody wrote a sentence about it.

`lib/hecks/doc/reference.rb` projects the combined live
`Syntax::Keyword` and `Syntax::Argument` records into one Markdown page per context —
`docs/implemented/reference/aggregate.md`, `docs/implemented/reference/command.md`, and so on —
regenerated by `bin/reference`. The generated part (signature, argument
table, `opens`/`fills`/status facts) lives between
`<!-- generated:begin word=... -->` / `<!-- generated:end -->` markers
and is rebuilt fresh every run; the prose after each marker is
hand-written and harvested back out before the page is rewritten, so
your writing survives regeneration. A brand-new word is seeded with a
`<!-- TODO: document this word -->` sentinel in place of prose.

`spec/reference_golden_spec.rb` checks two things. First, the same
frozen-file discipline the golden IR uses: every reference page must
equal what `bin/reference` would generate right now — a tree where the
declaration and the docs disagree refuses rather than drifting quietly,
same as the golden IR. Second, and this is the one that actually gates
a new word: `Reference.undocumented` walks every *live* (admitted or
deprecated) keyword row and fails the suite by name for any one whose
page still carries the TODO sentinel or no section at all. You may not
ship a word nobody can read about — that's the whole rule, enforced,
not aspirational.

So the last station in the checklist, after `bin/evolve admit` goes
green, is: run `bin/reference`, open the page for your word's context,
and replace the TODO with real prose. Nothing about `bin/evolve`
reminds you of this step directly — it's a separate gate, checked by a
separate spec, over a separate file — which is exactly why it belongs
on this list rather than being assumed.

## What this is all defending against

Every item on the checklist above exists because, at some point, a
change skipped exactly that item and something drifted silently while
the test suite stayed green. The sharpest version of that story on
record in this codebase isn't about the syntax table directly — it's in
`spec/corpus_spec.rb`'s own header, and it's worth reading in full,
because it's the reason gates like `syntax_conformance_spec` exist at
all: a new value-object rule landed, the example domains were migrated
to satisfy it, and `lib/hecks/grammar/expression.bluebook` — one
chapter, loaded by nothing in `spec/` — was left behind. It raised
`Malformed` at load. The hand-run corpus walk that would have caught it
died silently at its first stage. And `rspec` reported 358/358 the
whole time, because nothing in the suite ever booted that file, so
nothing was there to go red.

That is not a story about `expression.bluebook` specifically. It is
the general shape of every failure this guide's gates exist to close:
a thing that should agree with another thing, checked by nobody, so it
simply stopped agreeing and nothing noticed. `syntax_conformance_spec`
is that same insurance policy aimed at the distributed tables you now know how to
edit — before it existed, the language's own syntax records this guide walked
you through could have drifted from the builders exactly the way
`expression.bluebook` drifted from that value-object rule, and the
suite would have stayed green for the identical reason: nothing read
the two against each other. It does now. Every gate in this guide is
that same insurance, bought once, for one more pair of things that
used to be able to disagree in silence.
