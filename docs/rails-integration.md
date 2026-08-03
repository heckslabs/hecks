# A Rails integration for hecksagain

**Status: design only. Nothing in this document is built.** It records a session's
worth of reasoning about how a Rails app should sit on top of hecksagain as a driving
adapter — what to generate, what to hand-write, and several ideas that were
considered and specifically rejected, kept here so they aren't re-litigated later.

## The motivation, stated precisely

The starting instinct was "bye bye ActiveRecord" — not ActiveModel. Those are different
claims, and the difference matters:

- **ActiveRecord** infers a model's shape *from* the database schema — the migration is
  upstream, the Ruby class reflects it, and the two can drift. hecksagain already
  inverts this: a domain's shape is declared once, in its `.bluebook`, and the SQL
  schema is *projected* from it ("one column per attribute... never hand-written").
  Nothing about a Rails integration should reintroduce a second, database-derived
  source of truth.
- **ActiveModel**'s integration modules (`Naming`, `Conversion`, `Validations`) are not
  the problem and don't need replacing. Every attempt in this design to route around
  them (a hand-rolled `.errors`-duck-type, a bespoke `model_name` scheme) turned out
  worse than just using the real module. They're kept, deliberately, as a thin
  integration surface — never as a second place validations get authored.

The actual failure mode "ActiveRecord mess" points at has three named parts, and each
one maps to a specific thing this design avoids **structurally**, not by convention:

| Mess | Cause in ActiveRecord | Structural avoidance here |
|---|---|---|
| ORM-to-schema mapping | model shape reflects the DB | DB schema is projected *from* the domain, never the reverse |
| Entangled validations | validators are arbitrary Ruby, can call anything, run in unclear order | `given`/`ensures` are canonical text in a closed grammar (`\|\|`, `&&`, `.include?`, comparisons, literals, dotted paths) — nothing to entangle *with* |
| Bidirectional associations | `has_many`/`belongs_to` auto-load, cascade, `inverse_of` | every `reference_to` carries a value, never a loaded record; nothing loads until something explicitly asks |

## Architecture: Rails is a driving adapter, not a special one

Per the hexagonal (ports & adapters) reading: a Rails controller calling into the
domain is structurally identical to `bin/console` or `bin/run` — just another driving
adapter. The domain doesn't know or need to know which one called it. This has one
hard consequence for the design: **core `Handle`/`AggregateDoor` must never gain a
Rails or ActiveModel dependency.** Anything Rails-specific lives in a decoration layer
built on top of the core facade, applied once at boot — never inside
`lib/hecksagain/facade/`.

```
lib/hecksagain/facade/handle.rb      core, adapter-agnostic, used by bin/console too
  ↓ decorated once, at boot, for Rails specifically
WebHandle (Rails-only)               ActiveModel::Conversion + a real ActiveModel::Errors
WebDoor   (Rails-only)               wraps every Handle AggregateDoor hands out
```

`bin/console`/`bin/run` boot through the plain `AggregateDoor` and never load
ActiveModel. A Rails app boots through `WebDoor` instead. By the time a controller
sees a record, the decoration already happened — the controller never performs it.

## The core convention: `command` vs `command!`

Every non-creating verb becomes two real methods, both `define_singleton_method`
(never `method_missing` — see the bug below):

```ruby
name = Naming.snake(command.hecks_name)
define_singleton_method(name)       { command }                       # inspection — the bare IR::Command
define_singleton_method("#{name}!") { |**args| run(command, **args) } # dispatch — raises on refusal
```

The same rule applies uniformly to creating verbs on the module-level door. `command`
(no bang) is never a dispatch attempt — it returns `IR::Command` itself, which already
has `.attributes`, `.role`, `.goal` as readers. No separate `attributes_for(:command)`
helper, no symbol argument to misspell, and the form helper can take the object
directly: `bluebook_form_for(@account.freeze)`.

`command!` (bang) matches Rails' own `save!`/`update!` semantics exactly, not by
convention — hecksagain's refusals already *raise* (`GivenNotMet`, `TypeMismatch`,
etc.), never return false. Naming the non-raising form without a bang would be
misleading; naming the raising form *with* one is just accurate.

This convention deliberately gives up a boolean-returning `if @account.freeze` idiom
— that name now means inspection. Recovered in three lines via `rescue` where needed;
judged worth the trade for a name every command can use for both purposes with zero
redundant declaration.

## A real bug found along the way, independent of Rails

`Handle#method_missing`-based dispatch collides with real `Kernel`/`Object` methods.
Verified directly, not assumed:

```
COLLIDES  Freeze -> freeze   (Object#freeze)
COLLIDES  Open   -> open     (Kernel#open, private)
COLLIDES  Send   -> send     (Object#send)
```

`method_missing` only fires when Ruby finds no real method already defined —
`Object#freeze`/`#send` already exist, so `some_handle.freeze` silently calls
`Kernel#freeze` (returns `self`, marks the object Ruby-frozen) and never reaches the
domain at all. No error, no refusal — silent wrong behavior, the worst class of bug
this project generally hunts for.

`Account.open` is unaffected — it's a creating command, dispatched through
`AggregateDoor#define_singleton_method` on the module, and a directly defined
singleton method wins over an inherited `Kernel` method. The bug is specific to the
`method_missing` fallback path `Handle` currently uses for mutating verbs.

**Fix, independent of anything Rails-shaped:** define real methods for every verb at
`Handle` construction time (the `command`/`command!` pair above), rather than trusting
`method_missing` to catch them. This should be fixed in the library itself before any
of the rest of this document is built on top of it.

## Boot-time decoration (`WebHandle`)

```ruby
class WebHandle < SimpleDelegator
  include ActiveModel::Conversion

  def initialize(handle)
    super
    @errors = ActiveModel::Errors.new(self)
  end

  def model_name = ActiveModel::Name.new(nil, nil, __getobj__.fqn.split("::").last)
  def persisted?  = true   # a Handle only ever wraps an existing record — no "new" state exists
  def to_param    = id.to_s
  attr_reader :errors
end
```

`model_name` must be overridden at the *instance* level, not relied on at the class
level — `Handle` is explicitly one shared class across every aggregate ("not one
minted per aggregate"), so a class-level `ActiveModel::Naming` would make every
aggregate answer `"Handle"`. Rails' form/path helpers already know to prefer an
instance-level override when present.

`ActiveModel::Validations` is safe *only* as an empty container refusals get poured
into — `@account.errors.add(:base, e.message)` inside a `rescue`, never a hand-written
`validates` line beside it. The instant a real `validates` call appears here, there
are two authors for one rule again — the exact correlated-divergence risk the
Ruby/Rust discipline exists to prevent, recurring at the Rails boundary instead.

Params handed to a bang method should accept whatever Rails' `permit`-based object
looks like, without the caller pre-converting it:

```ruby
def run(command, args)
  identity = { @ir.identified_by => @id }
  @state = @dispatcher.dispatch("#{fqn}.#{command.hecks_name}", **identity,
                                 **args.to_h.transform_keys(&:to_sym)).instance.state
  self
end
```

`transform_keys(&:to_sym)`, not `symbolize_keys` — the latter is ActiveSupport-only
(`{}.respond_to?(:symbolize_keys)` is `false` without it loaded); the former is the
plain-Ruby idiom this codebase already uses in nine places (`policy_interpreter.rb`,
`value/coercion.rb`, every persistence adapter). Baking `symbolize_keys` into core
would repeat the exact "core gains a driving-adapter dependency" mistake ActiveModel
was kept out for.

## Routes: generated, GET/POST only, `only: [:show]` required

Nothing in this language maps to REST's generic `update`/`destroy` — every command is
a specific, narrow, named verb, never "replace this resource's representation
wholesale." Rails' own convention already reserves PUT/PATCH for exactly that generic
case and treats named custom actions as POST regardless of idempotency — so the whole
verb surface reduces honestly to two: GET for anything that reads, POST for anything
that writes.

```ruby
Rails.application.routes.draw do
  Hecks.boot("banking").registry.bluebooks.each_value do |bluebook|
    bluebook.aggregates.each do |aggregate|
      resource_name = Naming.snake(aggregate.hecks_name).to_s.pluralize.to_sym

      resources resource_name, only: [:show] do
        aggregate.commands.each do |command|
          scope = command.creates? ? :collection : :member
          send(scope) { post Naming.snake(command.hecks_name) }
        end
      end
    end
  end
end
```

`command.creates?` decides collection vs. member nesting — a creating command has
nothing to nest under yet; a mutating command already knows its subject. This is the
*same* fact that decides `Handle` construction, reused a second time for an unrelated
purpose, the way `@owner` was reused for both self-reference resolution and routing.

**`only: [:show]` is not optional.** Every write action ends in `redirect_to @account`,
which resolves through `model_name`/`to_param` to a *named route* — specifically the
conventional `show` route. Suppressing all default CRUD routes (`only: []`) leaves no
route for `redirect_to` to resolve against; it raises `ActionController::UrlGenerationError`
at runtime. This was silently broken across several earlier drafts of this design
before being caught.

`post :freeze` inside a `resources :accounts` `member` block maps to
`AccountsController#freeze` by plain Rails convention — no `to:`/`defaults:` needed,
and the member route's id param is `:id` by the same convention, not a custom
`:account_id` (an earlier draft got this wrong).

Entity-owned commands force nested routing, not by choice — verified directly.
`EntityInterpreter#call(domain, aggregate, dotted, args)` requires the aggregate
identity to already be resolved before an entity command can even be located; an
entity is literally a row inside its parent's own stored state
(`Array(instance[list_attr.name])`), saved back as the *parent's* `repository.save`.
There is no independent entity repository, so `/orders/:order_id/line_items/:line_item_id/...`
is the only shape that's even possible — not a convention someone chose.

## Controllers: named actions, generated as the default, overridable by name

Individually-named actions were chosen over a single generic `dispatch(params[:command])`
action for a specific, non-aesthetic reason: **application-specific concerns need a
polymorphic hook, and a generic action only has a `case`/`if` ladder to offer.**
That's the exact shape this project's own standing rule rejects — flatten with guard
clauses, extraction, or polymorphism, never nesting. Named methods give the
polymorphism for free through Ruby's own method dispatch; a shared `perform` gives the
default body:

```ruby
class AccountsController < ApplicationController
  before_action :set_account, except: [:open]

  def open
    @account = Account.open!(open_params)
    redirect_to @account, notice: "Opened"
  rescue *Hecksagain::Runtime::DOMAIN_REFUSALS => e
    Account.errors.add(:base, e.message)
    render :new, status: :unprocessable_entity
  end

  def freeze
    @account.freeze!(freeze_params)
    redirect_to @account, notice: "Frozen"
  rescue *Hecksagain::Runtime::DOMAIN_REFUSALS => e
    render :show, status: :unprocessable_entity
  end

  private

  def set_account   = @account = Account.find(params[:id])
  def open_params   = params.permit(*Account.open.attributes.map(&:name))
  def freeze_params = params.permit(*@account.freeze.attributes.map(&:name))
end
```

Read top to bottom, this is indistinguishable from a controller a Rails developer
wrote by hand for an ActiveRecord model — `@account.freeze!(freeze_params)` reads
exactly like `@account.update!(account_params)` would. Nothing about dispatch, IR, or
the two-runtime story is visible here; all of it stayed several layers below,
because none of it needed to leak up for the controller to be legible.

An app-specific concern (a Slack notification, a different redirect target) is a
plain method redefinition later in the same class body — no flag, no branch, no case
statement, and the other 43 generated actions stay exactly as uniform as before.

## Cross-references: values, hydration is explicit, composition is plain chaining

A `reference_to Account, as: :source` attribute carries the account's own identity
value — never a hydrated record. Confirmed directly against `IR::Reference#resolve`,
which returns the target's *declaration* (`IR::Aggregate`) for structural checks, not
a runtime instance, and against real usage in the corpus (`Transfer`'s own `given`s
compare `source != destination` as plain values, never `.balance`-style access).

Wanting the actual record is a deliberate, visible act — never automatic:

```ruby
class Handle
  @ir.attributes.select { |a| a.type.is_a?(IR::Reference) }.each do |ref|
    target = ref.type.target_name
    define_singleton_method("#{ref.name}_#{Naming.snake(target)}") do
      Facade.const_get(target).find(self[ref.name])
    end
  end
end
```

Purely additive — `transfer.source` (the raw value, still needed by `given`) is
untouched; `transfer.source_account` is a new, separate, on-demand accessor. Belongs
in *core*, not the Rails layer — it only reuses `AggregateDoor#find`, already
dependency-free.

**Chaining composes for free and should stay that way.** `transfer.source_account.customer`
is already a two-hop traversal, expressed as two ordinary calls, each individually
visible and individually lazy — nothing fires until called, and the first hop never
silently triggers the second. This is the deliberate opposite of `has_many ... through:`,
which hides how many lookups actually happened behind one call.

Two enrichments to `.find` were considered and rejected:

- **A `through:` option that chains hops automatically.** Rejected — this reintroduces
  exactly the "touching one thing implicitly loads several others" pattern named as
  the root of association-mess earlier in this document. Plain chaining already gives
  the same capability, honestly.
- **Filtering built into `.find` by default.** Rejected — `.find` has exactly one job
  (resolve one identity to one record) and stays unambiguous because of it. Filtering
  by criteria is already `query`'s whole purpose (`query "InGoodStanding"`, `where`,
  the richer option vocabulary in `reflex.bluebook`) — merging the two would repeat the
  same overload pattern that has produced a real bug nearly every other time it's
  appeared in this project (`identity_of`/`identity_from`'s fallback chain,
  `AlreadyExists` from blurring create and mutate).

## Also considered and rejected, kept for the record

- **A `creates`/`mints` DSL keyword**, explicitly declared, replacing the self-reference
  inference. Rejected: splits one fact (nilable `@references`, safe by construction —
  a Ruby ivar can't be both nil and a type name) into two independently-settable facts
  that can now contradict, requiring a new guard to catch what used to be structurally
  impossible. "Agreement by construction" beats "agreement by checking," the same
  distinction this project already draws for the Ruby/Rust boundary.
- **`reference_to self`**, sugar removing the redundant type-name repetition. Mechanically
  sound (an identity check against the builder instance, zero wire-format change) but
  rejected on legibility grounds — `self` is a programmer's word, not a domain reader's;
  the existing corpus already made this exact call once (`Transfer`'s comment on why
  `source.value` was wrong: "a clerk would not say it that way either").
- **Inferring create-vs-mutate from the persistence adapter** (find-or-mint). Rejected:
  requires every mutating command to also accept full business-identity attributes
  (losing the reference-key convenience a saga/caller relies on), and resurrects the
  exact double-creation bug `AlreadyExists` was built to catch — a second `OpenTill`
  call would silently be reinterpreted as a mutate instead of refused.
- **Deriving HTTP PUT/PATCH from `lifecycle`-transition gating.** The underlying
  observation is real (a lifecycle-gated command like `Freeze` is genuinely
  retry-safe — `admissible_transition` runs before `apply_mutations`, so a repeat is
  refused, not reapplied — while a plain-`:set`-mutation command like `Suspend` is
  *also* safe for an unrelated reason, and an incrementing command like `TakeIn`
  never is). Rejected as a *routing* decision anyway: Rails' PUT/PATCH is reserved for
  the generic `update` action, which nothing in this language has an equivalent of —
  every command is a specific named verb. POST-for-every-write is not a simplification
  so much as the semantically honest choice.
- **A single generic `dispatch` action** reading the verb from `params[:command]`.
  Functionally fine, but loses view-resolution-by-convention (`dispatch.html.erb` for
  everything, not `freeze.html.erb`), loses `except:`/`only:` callback filtering by
  action name, and gives application-specific concerns nowhere to hang except a
  conditional. Superseded by named generated actions.

## Explicitly open, not designed here

- **Batch reads across a reference — a real SQL `JOIN`.** Verified directly: the only
  real `JOIN` anywhere in the adapter layer is Postgres introspecting its own
  `pg_class`/`pg_inherits` system catalog for the era/lineage machinery; nothing in
  `query_specification` crosses a `reference_to` into another aggregate's table.
  `.find`/plain chaining (above) is the right tool for one record, on demand — it does
  not and should not solve the *list* case: `Transfer.all.each { |t| t.source_account.customer.name }`
  is genuine N+1, one query becoming up to 2N+1. The right shape is a **new, explicit
  extension to `query`** (a `join`-declaring clause, compiled to a real `JOIN` on an
  adapter that supports one, refused at declaration time on one that doesn't) — kept
  structurally separate from `.find`, the same way `.find` and `query` were already
  kept separate for filtering. Not designed further than that shape here.
- **The read side, more broadly.** `query`/read-model declarations (`query "InGoodStanding"`, the
  richer option vocabulary in `reflex.bluebook`) have no generated-route or
  generated-view story yet. `show` is the one slice that's load-bearing today (nothing
  else makes `redirect_to` work) — `index` and filtered/query-backed views are a
  separate, larger, still-undesigned piece.
- **Authorization.** `command.role` is descriptive only — verified directly, zero
  references anywhere in `lib/hecksagain/runtime`. Whether/how a Rails app enforces
  "only a Compliance officer may Freeze" is undecided. Per the hexagonal reading, this
  almost certainly belongs on the driving-adapter side (Rails), not the domain — the
  domain shouldn't need to know who's allowed to call it any more than it needs to
  know how it was called.
- **Labels/help text for individual attributes.** `goal`/`description`/`role` exist at
  the command/aggregate level; nothing per-attribute exists beyond a name and a type.
  A real form needs human-readable labels somewhere — either humanized mechanically or
  the language grows a small, additive (non-semantic, no parity concern) annotation.
- **File uploads or any attribute type with no natural HTML representation.** Not
  encountered in the corpus; not designed for.
- **Real-time updates** (ActionCable as a driven adapter, pushing domain events to a
  live browser). Named as plausible, not designed.
- **Which driven adapters should be Rails-native vs. Rails-agnostic** — `ActionMailer`/
  `ActiveJob` are convenient specifically because the process already runs inside
  Rails, not because they're architecturally required. Treated as a per-port choice,
  same convention as `sqlite`/`memory`, not a default.
