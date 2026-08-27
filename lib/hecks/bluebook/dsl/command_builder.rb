require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      class CommandBuilder
        GRAMMAR_CONTEXT = "Command"

        include AttributeCollector
        include RuleReference
        include WordGate

        # Vendored addition, not (yet) upstream hecks (migration plan
        # task 4): a sentinel for "this keyword was never passed", distinct
        # from Ruby's own nil/false. `then_set`'s ORIGINAL default (`to:
        # nil`) could not tell "not given" apart from "given, and the
        # value IS false" — `to || from` silently treats `to: false` the
        # same as an absent `to:` and falls through to `from` (also
        # absent), so `then_set :accepted, to: false` raised "names no
        # operation" for the one value most likely to be written that way
        # (a boolean flip). Confirmed real, live: miette's
        # dream_interpretation.bluebook (`then_set :accepted, to: false`)
        # and transparency.bluebook (`then_set :always, to: false`). TODO
        # upstream via bin/evolve.
        UNSET = Object.new.freeze
        private_constant :UNSET

        def initialize(name, owner: nil, from: nil, named_givens: {}, owner_attributes: [], owner_constructs: [],
                       entity_shared_givens: {})
          @name              = name
          @owner             = owner
          @givens            = []
          @ensures           = []
          @mutations         = []
          @emits             = []
          @named_givens      = named_givens
          @owner_attributes  = owner_attributes
          @owner_constructs  = owner_constructs
          # THE AGGREGATE-WIDE cross-entity pool — see
          # `AggregateBuilder#entity`'s own comment and `EntityBuilder#
          # given`'s. Empty (never populated) for an AGGREGATE-owned
          # command, which already checks its own owner's `named_givens`
          # directly and has no siblings to reach across; real only for
          # an ENTITY-owned command's own bare reference.
          @entity_shared_givens = entity_shared_givens
          # NORMALIZED the exact same way `StateTransition#from` already
          # is — one state or several, a single spelling either way,
          # both read back through `Array(...)` at check time.
          @from = case from
                  when Array then from.map(&:to_s)
                  when nil   then nil
                  else            from.to_s
                  end
        end

        # A command carries ONE responsibility role — the language never
        # declared an OR between two roles, so a second `role` call would
        # otherwise silently win while the first still looked declared,
        # exactly the failure mode `reference_to`'s own duplicate guard
        # (below) already exists to prevent for a command's root.
        #
        # RENAMED FROM `role` — item #13's full metaprogrammed dispatch
        # (slice 4). This is a uniqueness gate on PRIOR STATE (`@role`
        # already set), not a pure function of the argument's own value —
        # a genuinely different shape than a plain fill, so it stays
        # hand-written and is reached through `calls:` like `attribute`
        # was in slice 3. Bootstrap-reachable (every self-hosted command
        # declares a role), so also named in
        # `GenericDispatch::BOOTSTRAP_CALLS_FALLBACK`.
        def role_impl(value)
          raise Malformed,
                "#{@name} declares role twice — a command carries ONE " \
                "responsibility; the second would silently win and the " \
                "first would still look declared" if @role

          @role = value
        end

        def goal(value) = @goal = value

        # See AggregateBuilder#provenance's own comment — identical shape,
        # one level down.
        # RENAMED FROM `provenance` — item #13's full metaprogrammed
        # dispatch (slice 4c). Bootstrap-reachable, in
        # GenericDispatch::BOOTSTRAP_CALLS_FALLBACK.
        def provenance_impl(from:) = @provenance = from

        # `optional:` rides here as well as on a plain attribute : `as:` makes a
        # reference into a NAMED ARGUMENT, and a named argument is exactly the kind
        # of fact that may or may not be given. The meta-domain's Verb.Declare
        # points at the Entity a command belongs to — and most commands belong to no
        # entity at all.
        # RENAMED FROM `reference_to` — item #13's full metaprogrammed
        # dispatch (slice 4b). Bootstrap-reachable, in
        # GenericDispatch::BOOTSTRAP_CALLS_FALLBACK.
        def reference_to_impl(type, as: nil, optional: false)
          demodulised = Naming.demodulise(type)
          # moved to the language: given "a command names what it acts on", on Verb.ActsOn

          # `as:` MEANS "a named attribute", not "the root I act on" — so a command
          # can point at another instance of its OWN kind. Without this,
          # `reference_to Aggregate, as: :points_at` on a command owned by Aggregate
          # read as a second self-reference and was refused as naming two roots,
          # which is how the meta-domain's own Aggregate.Reference could not say the
          # one thing it exists to say. Transfer has said
          # `reference_to Account, as: :source` for as long as banking has existed;
          # this is the same sentence when the target happens to be the owner.
          return cross_reference(demodulised, as, optional) if as || demodulised.to_s != @owner.to_s

          if @references
            raise Malformed,
                  "#{@name} references #{@owner} twice — a command acts on ONE " \
                  "root ; the second would silently win and the first would " \
                  "still look declared"
          end

          @references = demodulised
        end

        private

        def cross_reference(target, as, optional = false)
          attribute_impl(as || default_reference_name(target), Reference.new(target), optional: optional)
        end

        public

        # NO BLOCK is a REFERENCE, not a fresh declaration (S10, ADR
        # 0025 — "a precondition shared across commands is declared
        # once. An aggregate declares it by name and commands
        # reference it"): the SAME word, the SAME shape
        # (`AggregateBuilder#given`, block required there), so naming a
        # precondition back is spelled exactly like declaring one would
        # be, minus the block — one idea, one word, never a second
        # spelling ("requires"/"precondition") for "use the one already
        # named". Resolved against whatever the OWNING aggregate has
        # declared so far — see `AggregateBuilder#command`'s own
        # comment on why that means declaration order matters here.
        # RENAMED FROM `given` — item #13's full metaprogrammed dispatch
        # (slice 4b), same reasoning as reference_to_impl above.
        def given_impl(description, &predicate)
          return reference_named_given(description) unless predicate

          # moved to the language: given "a rule says what it means", on Verb.Rule

          @givens << build_rule(Given, description, predicate, owner_name: @name, word: "given",
                                 extraction_failure: "its source could not be read, so no other runtime could ever evaluate it")
        end

        private

        # PRIMITIVE 1 (RuleReference#resolve_hash_chain) — FIRST this
        # command's own owner (as always), THEN — only for a piece-owned
        # command, where it is real — a SIBLING piece's own entity-level
        # declaration under the SAME aggregate (`@entity_shared_givens`,
        # threaded from `EntityBuilder#given`'s own write-through).
        # "customer is active" declared once on `Visit`, referenced bare
        # by `KeyIssuance.Return` — two different pieces, same aggregate,
        # same predicate — is exactly the shape this second pool exists
        # for.
        def reference_named_given(description)
          verify_resolves_via!("given", "Command", "hash_chain")
          named = resolve_hash_chain([@named_givens, @entity_shared_givens], description) ||
                  raise(Malformed,
                        "#{@name}'s given #{description.inspect} names no precondition " \
                        "#{@owner} declares, and no sibling piece under the same " \
                        "aggregate declares it either — declare it once with a block " \
                        "(#{@owner}'s own given(#{description.inspect}) { ... }), before " \
                        "the commands that reference it")

          @givens << named
        end

        public

        # The POSTCONDITION — a given for the far side of the mutations,
        # evaluated against the settled record with `old` naming the state
        # as it stood before them: `ensures("...") { old.balance.cents ==
        # balance.cents + amount.cents }`. Same extraction, same Rule
        # shape, same refusal form; EnsuresNotMet instead of GivenNotMet.
        def ensures(description, &predicate)
          @ensures << build_rule(Given, description, predicate, owner_name: @name, word: "ensures",
                                  extraction_failure: "a postcondition is carried as text, and this one has none")
        end

        # `sets` is the word; `then_set` is the spelling every existing
        # bluebook was written under (Syntax::Keyword carries the rename as
        # `was:`), and it stays answered here forever — a renamed word's old
        # era keeps booting, which is the whole point of the rename column.
        #
        # Vendored addition, not (yet) upstream hecks: `then_set
        # :target, from: :source_field` (hecks_conception/miette, found
        # live in body/doctor/bluebook/doctor.bluebook) -- semantically
        # identical to `to:` (copy this argument/field into the target),
        # different word. TODO upstream via bin/evolve (migration plan
        # task 7): decide whether `from:` or `to:` becomes the canonical
        # spelling.
        #
        # Vendored addition, not (yet) upstream hecks (migration plan
        # task 4, i106 in-DSL math): `multiply:`/`clamp:` -- per-tick organ
        # math (miette's body/organs/bluebook: strength decays ×0.98,
        # weight/strength clamp to [0, 1]) that used to be shell-side awk
        # and moved into the bluebook itself. `multiply:` mirrors
        # increment/decrement's shape exactly (a Numeric amount, applied
        # by CommandRules::Arithmetic -- see that file's own comment on
        # the matching Float-support widening this required). `clamp:`
        # is a genuinely different shape -- its source is always a literal
        # `[min, max]` pair, never an argument reference, and it bounds
        # the CURRENT value rather than combining it with an amount -- so
        # it does not reuse `arithmetic`/`arithmetic_value_object` at all;
        # see MutationApplier#apply's own `:clamp` branch.
        #
        # `remove:` -- vendored addition, not (yet) upstream hecks
        # (migration plan task 4): the list-removal counterpart to
        # `append:` (plan.bluebook's own RemoveDependency/DeactivateSprint
        # commands: "the runtime list-remove primitive (then_set remove:)
        # drops it from the list element-wise, with no read-modify-write
        # -- so a concurrent Add can never be lost"). Matches an element
        # by VALUE equality against `mutation.source` (resolved and
        # Value-coerced the same way increment/decrement/multiply already
        # coerce their own amount -- see MutationApplier#removed).
        #
        # `sets :field, true` -- vendored addition, not (yet) upstream
        # hecks (migration plan task 8): a bare positional literal
        # instead of `to:` -- 14 occurrences across hecks_nursury
        # (oceanography.bluebook/volcanology.bluebook and others),
        # always a boolean shorthand (`sets :deployed, true`, never
        # a string/number positional -- checked directly, zero non-
        # boolean occurrences of the bare-positional-second-arg shape
        # anywhere in the corpus). Folded into `to:` itself rather than
        # given its own mutation op -- semantically identical, same
        # UNSET-sentinel discipline the `to: false` fix already
        # established (a positional `false` must read as "set to
        # false," not "absent," same as the keyword form). Only applied
        # when `to:` itself was NOT also given, so an explicit `to:`
        # keyword always wins over a stray positional.
        #
        # `sets` is the word (ADR 0025 reverts `then_set` — the grammar
        # already declared `sets`, `was: "then_set"`, and 143 of 143 live
        # call sites are `then_set`, so this method was the one thing
        # still backwards). `to:` is OMITTABLE when it would only repeat
        # the target — `sets :number` alone already means `to: :number`
        # — and the REDUNDANT explicit spelling is refused outright
        # (principle 1, "one idea, one spelling": `sets :number, to:
        # :number` says nothing `sets :number` doesn't). `from:` — a
        # pure synonym for `to:` the language's own refusal message had
        # already forgotten about — is gone; write `to:`.
        # THE OP EACH KWARG SELECTS — `spec/syntax_conformance_spec.rb`'s own
        # "selects the same op..." check holds this constant to the self-
        # hosted table's own `Argument#selects` column (`"op=set"`,
        # `"op=append"`, ...; whole-project table-unification survey, item
        # #1), the same field `rust/parser/src/keywords.rs`'s `ArgumentRow.
        # selects` already carries. `to:` is the one kwarg whose own name
        # differs from the op it selects — every other kwarg selects the op
        # of its own name.
        KWARG_TO_OP = { to: :set, append: :append, increment: :increment, decrement: :decrement,
                        multiply: :multiply, clamp: :clamp, remove: :remove }.freeze

        # RENAMED FROM `sets` — item #13's full metaprogrammed dispatch
        # (slice 4c). The `KWARG_TO_OP` op-selection mapping is already
        # table-verified (`Argument#selects`), but the REST (UNSET-
        # sentinel discipline, redundant-spelling refusal, omittable-
        # `to:` fallback, one-mutation-only refusal, the position-
        # preserving `resolve_*!` reinsertion) is keyed off RUNTIME
        # STATE, not a pure function of a static row — stays hand-
        # written, reached through `calls:` like everything else here.
        # Bootstrap-reachable, in BOOTSTRAP_CALLS_FALLBACK.
        def sets_impl(target, positional_to = UNSET, to: UNSET, append: UNSET,
                      increment: UNSET, decrement: UNSET, multiply: UNSET, clamp: UNSET, remove: UNSET)
          # moved to the language: given "a mutation names a target", on Verb.Change

          to = positional_to if to.equal?(UNSET) && !positional_to.equal?(UNSET)

          # `to:` only ever REPEATS the target when it's a Symbol naming a
          # field — a literal (`to: false`, the bare positional-boolean
          # shorthand, a String, ...) is a VALUE, never a redundant name,
          # so it never has `.to_sym` to compare in the first place.
          if to.is_a?(Symbol) && to == target.to_sym
            raise Malformed,
                  "#{@name}'s sets :#{target}, to: :#{target} repeats the target — " \
                  "sets :#{target} alone already means the same"
          end

          given = { to: to, append: append, increment: increment, decrement: decrement,
                    multiply: multiply, clamp: clamp, remove: remove }
                  .reject { |_, source| source.equal?(UNSET) }
          named = given.to_h { |kwarg, source| [KWARG_TO_OP.fetch(kwarg), source] }

          # THE OMITTABLE CASE. No operation was named at all — not even a
          # bare `to:` — so this is `sets :field` alone, which means
          # exactly what the redundant, refused spelling above would have.
          named = { set: target } if named.empty?

          if named.size > 1
            raise Malformed,
                  "#{@name}'s sets :#{target} tries to #{named.keys.join(' and ')} " \
                  "at once — one mutation, one meaning"
          end

          op, source = named.first
          @mutations << Mutation.new(target: target.to_sym, op: op, source: normalize_append_source(op, source))
        end

        # LEGACY UNDER SHADOW-PARSING (S0a's own bridge) — frozen era text
        # minted before this rename still parses; live source refuses it,
        # naming the replacement.
        # RENAMED FROM `then_set` — item #13's full metaprogrammed
        # dispatch (slice 5). Not bootstrap-reachable. Now has its own
        # dedicated, `status: "deprecated"` Keyword row (syntax.bluebook)
        # rather than living only as `sets`'s own `was:` — see that
        # row's own comment for why.
        def then_set_impl(target, positional_to = UNSET, **kwargs)
          return legacy_then_set(target, positional_to, **kwargs) if MetaValidator.shadow_parsing?

          raise Malformed, "#{@name}'s then_set is gone — sets is the word now"
        end

        # No raise here. "an event is named" is declared in the language itself —
        # language/bluebook/behavior.bluebook, on Command.Announce — and MetaValidator is what
        # enforces it. This is the first rule to move ACROSS rather than be
        # duplicated : delete the declaration and an unnamed event is accepted,
        # which is what makes the meta-domain load-bearing rather than decorative.
        def emits(event_name)
          @emits << event_name.to_s
        end

        # THE RECORD'S OWN VALUE AS A MUTATION SOURCE — `sets :positions,
        # append: { ply: state(:ply), knights: state(:knights) }` copies
        # what the record holds NOW into the new element; `sets :last,
        # to: state(:current)` copies one field onto another. A bare
        # Symbol always names an argument (see `resolve_append_fields!`),
        # so without this a command could not snapshot its own state at
        # all. `Literal::StateRef`'s own comment has the wire spelling.
        def state(name) = StateRef.new(name.to_sym)

        # THE SYNCHRONOUS COUSIN OF `trigger` — an AGGREGATE-level command
        # that hands its own dispatch to ONE nested entity command, checked
        # and applied within the SAME atomic dispatch rather than a second
        # one. Built because `trigger`/`saga`'s own dispatch (`Dispatcher
        # #reenter`) is a REACTION — the triggering command has already
        # committed by the time it runs, and both `PolicyInterpreter#deliver`
        # and `SagaInterpreter#deliver_saga_dispatch` rescue a target's own
        # refusal and RECORD it rather than raising it back to the original
        # caller. That is correct for what those two exist for (an
        # eventually-consistent process that can compensate), and wrong for
        # a caller who needs a synchronous yes/no on whether the thing they
        # asked for actually happened — a chess move's own legality, for
        # instance, checked live building `domain/chess` in a downstream
        # project. `delegates_to` fills exactly that gap: the target
        # entity command's own `given`/`ensures` are enforced as real,
        # unrescued Ruby exceptions, so a refusal deep in the entity's own
        # rules is the DELEGATING command's own refusal too, and nothing
        # from either side is saved unless both sides pass.
        #
        # `target` is always ONE hop, `"Entity.Command"` — an aggregate
        # names the entity it owns directly, same reach a bare `given`
        # reference already has (see `Knight`'s own comment on this
        # domain's shared givens), not a multi-segment dispatch chain.
        # `with:` resolves the SAME way `sets ..., append: {...}`'s own
        # field map and a policy's own `trigger ..., with: {...}` already
        # do: each value names one of THIS command's own declared/implicit
        # arguments, read at dispatch time and handed to the target under
        # its own key.
        #
        # MUTUALLY EXCLUSIVE with `sets`/`emits` on the SAME command — a
        # delegating command is a pure passthrough by design (see this
        # method's own header), so it declares no OTHER mutation or event of
        # its own; its result IS whatever the delegated entity command's own
        # `sets`/`emits` produced. Enforced in `build`, once every builder
        # call has already run, so declaration order does not matter.
        #
        # STORED AS A MUTATION, not a new Command field — a real, deliberate
        # choice, not a shortcut. `Command`'s own shape (givens/ensures/
        # mutations/emits/...) is not just Ruby: it round-trips through this
        # language's OWN self-hosted meta-domain (`Bluebook::MetaValidator`
        # dispatches every declaration into a "Bluebook" domain describing
        # itself, then REBUILDS the real runtime graph from what THAT domain
        # holds — `Hecks.bluebook` registers what `MetaValidator.call`
        # returns, never the builder's own object graph directly, confirmed
        # by reading `meta_validator.rb`'s own `self.call`/`self.hold`).
        # A genuinely NEW top-level Command field needs the meta-domain's
        # own grammar (`language/bluebook/behavior.bluebook` or wherever
        # Verb.Rule/Ensure/Change live) taught to carry it too — the same
        # scale of change as the real "item #13" migration this file's own
        # comments document throughout. A NEW MUTATION OP does not: `sets`'s
        # own `mutations:` field is ALREADY a fully round-tripped part of
        # that contract (`Assembly::CONTRACTS["Command"].fields[:mutations]`),
        # and an append-shaped mutation ALREADY carries a multi-key `fields:`
        # hash the exact shape `with:` needs — so `delegates_to` rides that
        # existing, already-correct wire format under a new `op: :delegate`
        # instead of inventing a parallel one. `MutationOp`'s own closed set
        # (vocabulary.bluebook) gained `"delegate"` alongside `"append"`
        # for exactly this reason, and the THREE meta-domain touch points
        # that hard-coded `op == "append"` for the multi-binding shape
        # (`meta_validator/readings.rb#mutation_rows`,
        # `meta_validator/shapes.rb#mutation`, `assembly/marks.rb#mutation`)
        # now check for `:delegate` alongside it, each with a comment
        # pointing back here.
        # RENAMED FROM `delegates_to` to `delegates_to_impl` on declaration
        # — matches `sets_impl`/`given_impl`/`reference_to_impl`'s own
        # convention (language/bluebook/syntax.bluebook's own Keyword row
        # for this word names `calls: "delegates_to_impl"`), the same
        # `word`-vs-`_impl` split every hand-written (not yet item-#13-
        # generic-dispatch-migrated) DSL word here already follows.
        def delegates_to_impl(target, with: {})
          entity_name, _dot, command_name = target.to_s.rpartition(".")
          if entity_name.empty? || command_name.empty?
            raise Malformed,
                  "#{@name}'s delegates_to #{target.inspect} does not name an entity and a command " \
                  "(\"Entity.Command\") — the same one-hop shape a bare given reference already uses"
          end

          @mutations << Mutation.new(target: target.to_s, op: :delegate, source: with)
        end

        # A COMMAND DECLARING WHAT PAST FACT IT AMENDS — the append-only
        # answer to "what if this record's history turns out to have been
        # wrong": never rewrite the original event (the log stays exactly
        # what it was), always append a NEW fact on top. `event` names the
        # event this command corrects; `as:` optionally binds the located
        # instance for a `given`/`ensures` to reference, the same shape
        # `ensures`'s own `old` binding already has; `reason:` is not
        # descriptive-only the way `goal` is — it is carried as data, the
        # one thing an audit trail actually needs ("we corrected this, and
        # here is why"), refused when blank the same way a `given`'s own
        # description is required to say something.
        #
        # STORED AS A MUTATION, not a new Command field — see the
        # KeywordSeed row's own comment (command.bluebook) for why: this
        # is the exact same choice `delegates_to` already made, for the
        # exact same reason. Rides the SAME multi-binding wire shape
        # `append`/`delegate` use — `as:`/`reason:`/`reverses:` assembled
        # by hand into one `source` hash, the way `sets_impl` assembles up
        # to seven kwargs into one `named` hash above.
        #
        # `reverses: true` NAMES an intent to auto-derive the corrective
        # `sets` from the original event's own mutations, rather than the
        # author writing it — see `AggregateBuilder#seal_correction_targets`,
        # where that derivation actually happens (it needs every sibling
        # command in the aggregate already known, which this builder alone
        # cannot see). MUTUALLY EXCLUSIVE with an explicit `sets` on the
        # same command — two ways of saying the same thing is exactly the
        # redundancy `sets`'s own omittable-`to:` rule refuses elsewhere.
        #
        # `as:` IS ALWAYS STORED AS TEXT, never left a bare Symbol —
        # `Mutation#classified_source`/`#appended_fields` (Behaviour::
        # Mutation) classify any bare Symbol field as `kind: "argument"`,
        # meaning "resolve this against one of THIS command's own declared
        # attributes at dispatch time" (append/delegate's own meaning for a
        # Symbol). `as:` names no such thing — it is a plain label, not yet
        # wired into the expression evaluator (a future round's work, once
        # a real runtime consumer exists) — so coercing it to a String here
        # keeps it out of that machinery entirely rather than silently
        # miscategorised as an unresolvable argument reference.
        def corrects_impl(event, as: nil, reason: nil, reverses: false)
          if reason.to_s.strip.empty?
            raise Malformed,
                  "#{@name}'s corrects #{event.inspect} names no reason — a correction " \
                  "is carried as data (an audit trail needs to say WHY), the same way a " \
                  "given's own description must say something"
          end

          @mutations << Mutation.new(target: event.to_s, op: :corrects,
                                     source: { as: as&.to_s, reason: reason.to_s, reverses: reverses })
        end

        def build
          resolve_implicit_attributes!

          delegation = @mutations.find { |mutation| mutation.op == :delegate }
          if delegation && (@mutations.size > 1 || @emits.any?)
            raise Malformed,
                  "#{@name} both delegates_to #{delegation.target} and declares its own " \
                  "sets/emits — a delegating command is a pure passthrough (see delegates_to's " \
                  "own comment); its result is the delegated command's own"
          end

          Command.declare(
            name:       @name,
            role:       @role,
            goal:       @goal,
            attributes: attributes,
            givens:     @givens,
            ensures:    @ensures,
            mutations:  @mutations,
            emits:      @emits,
            references: @references,
            from:       @from,
            provenance: @provenance
          )
        end

        def self.build(name, owner: nil, from: nil, named_givens: {}, owner_attributes: [], owner_constructs: [],
                       entity_shared_givens: {}, &block)
          builder = new(name, owner: owner, from: from, named_givens: named_givens,
                        owner_attributes: owner_attributes, owner_constructs: owner_constructs,
                        entity_shared_givens: entity_shared_givens)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # RESOLUTION RULES — see `docs/resolution-rules/README.md` for the
        # precise, language-agnostic algorithm each of `resolve_bare_set!`/
        # `resolve_append_fields!` implements (`implicit-command-attributes.md`
        # / `implicit-append-fields.md`) — the contract a Rust mirror is
        # written from, not inferred from this comment.
        #
        # `sets :field` ALONE (S5's own bare form — no `to:`, meaning
        # `to: :field`) already says the command accepts an argument
        # named `:field`; requiring a SEPARATE `attribute :field, Type`
        # line that retypes what the owning aggregate/entity already
        # declared is the same redundancy S10's `given` reference already
        # killed for preconditions ("a precondition shared across
        # commands is declared once... a command references it by
        # name"). Same move here, one level down: when the command
        # hasn't declared its own `:field`, import the OWNER's
        # already-built `Attribute` verbatim (same type, pattern,
        # optional, admits) instead of retyping it.
        #
        # Only the exact self-referential shape qualifies — `sets
        # :field, to: :other` names a genuinely different source and
        # stays exactly as explicit as it always was; `sets :field, to:
        # false` (or any other literal) isn't naming an argument at all.
        # Comparing as text rather than identity handles both sides
        # (`source` carries whatever `target` was passed as; `target`
        # itself is always symbolized) without caring which.
        #
        # Declaration order matters here the same way it already does
        # for `identified_by`/`given` — the owner's own attribute must
        # exist by the time THIS builder's `build` runs, which every
        # real bluebook already satisfies (the aggregate/entity always
        # declares its attributes before the commands that act on them).
        def resolve_implicit_attributes!
          @mutations.each do |mutation|
            case mutation.op
            when :set    then resolve_bare_set!(mutation)
            when :append then resolve_append_fields!(mutation)
            end
            refuse_unknown_state_sources!(mutation)
          end
        end

        # `state(:name)` names one of the OWNER'S OWN fields — a snapshot
        # of something the record actually holds. Refused at build, by
        # name, the way an unknown `given` reference is; nothing here can
        # read a field the aggregate never declared.
        def refuse_unknown_state_sources!(mutation)
          sources = mutation.source.is_a?(Hash) ? mutation.source.values : [mutation.source]
          sources.grep(StateRef).each do |ref|
            next if @owner_attributes.any? { |attr| attr.name == ref.name }

            raise Malformed, "#{@name}'s sets :#{mutation.target} reads state(:#{ref.name}), " \
                             "which the owner does not declare"
          end
        end

        def resolve_bare_set!(mutation)
          # A SYMBOL naming its own target — never a literal that merely
          # spells the same word. `sets :moved, to: "moved"` (a chess rook
          # recording that it has moved, into a closed set whose member is
          # literally "moved") used to read as the shorthand and import
          # the owner's `moved` attribute onto the command — a phantom
          # argument nothing ever passes, harmless at runtime only
          # because the owner's default filled it, and a real, silent
          # divergence for every projection that reads the command's
          # declared arguments.
          return unless mutation.source.is_a?(Symbol) && mutation.source.to_s == mutation.target.to_s
          return if attributes.any? { |attr| attr.name == mutation.target }

          owner_attr = @owner_attributes.find { |attr| attr.name == mutation.target }
          attributes << owner_attr if owner_attr
        end

        # ONE HOP DEEPER than `resolve_bare_set!` — an `append:` mutation
        # (`sets :ledger, append: { narrative: :narrative, ... }`) builds
        # a NEW element of a LIST field, not the command's own root
        # record, so a bare self-referential field inside it (the hash
        # key equals its own value, same shorthand `resolve_bare_set!`
        # already reads) can't resolve against `@owner_attributes` — the
        # aggregate itself never stores `:narrative`, only the list
        # element's own construct does (`attribute :ledger,
        # list_of(LedgerEntry)`, and `LedgerEntry` is what actually
        # declares `:narrative`). Resolves the list field's own element
        # TYPE first (`element_type_for`), then that construct's own
        # attribute of the same name — same verbatim-import, one level
        # further down the same reasoning `resolve_bare_set!`'s own
        # comment already gives.
        #
        # A non-self-referential value (`direction: { value: "credit" }`,
        # a nested literal) is untouched — only a bare symbol equal to
        # its own key ever qualifies, identical to `resolve_bare_set!`'s
        # own target/source text comparison.
        #
        # POSITION-PRESERVING, not appended at the end — the exported IR
        # is array-order-sensitive (attributes carry their own declared
        # order onto the wire), so an append's fields are resolved as
        # ONE CONTIGUOUS GROUP, in the mutation's own hash order,
        # reinserted at whichever position the group's leftmost STILL-
        # DECLARED member already occupies (or the end, if every member
        # of the group is resolved). A plain `attributes << owner_attr`
        # here would only ever reproduce the original order when the
        # missing field happened to already be last — real, live
        # evidence: `Keyword#was`/`Argument#variadic` (both genuinely
        # last in their own append hash) round-tripped correctly under
        # the naive append; every OTHER field in the same hash did not,
        # caught by this codemod's own reboot-and-diff safety net rather
        # than silently landing wrong.
        def resolve_append_fields!(mutation)
          return unless mutation.source.is_a?(Hash)

          element = element_type_for(mutation.target)
          return unless element

          self_ref_fields = mutation.source.select { |field, value| value.is_a?(Symbol) && value.to_s == field.to_s }.keys
          return if self_ref_fields.empty?

          present = self_ref_fields.filter_map { |field| attributes.find { |attr| attr.name == field } }
          return if present.size == self_ref_fields.size # already fully declared — nothing to resolve

          anchor = present.empty? ? attributes.length : present.map { |attr| attributes.index(attr) }.min
          attributes.reject! { |attr| present.include?(attr) }

          group = self_ref_fields.filter_map do |field|
            present.find { |attr| attr.name == field } || element.attributes.find { |attr| attr.name == field }
          end
          attributes.insert(anchor, *group)
        end

        # The owner's own LIST attribute names its element type as TEXT
        # (`Attribute#type`, unwrapped from `list_of(...)` at declare
        # time) — resolved against `@owner_constructs` (the owner's own
        # value objects and entities, the only two kinds an element can
        # be) by `hecks_name`, the same lookup
        # `AttributeCollector#resolve_identity_field!` already uses for
        # a value object's own name.
        def element_type_for(list_field)
          list_attr = @owner_attributes.find { |attr| attr.name == list_field && attr.list? }
          return nil unless list_attr

          @owner_constructs.find { |construct| construct.hecks_name.to_s == list_attr.type.to_s }
        end

        # LEGACY — see `then_set`'s own comment. The ORIGINAL implementation,
        # verbatim: `from:` still a synonym for `to:`, no omittable-`to:`
        # shorthand, no refusal for the redundant `to: target` spelling —
        # frozen era text was minted under this reading, and a legacy
        # grammar exists precisely so re-parsing it never silently changes
        # what it meant.
        def legacy_then_set(target, positional_to = UNSET, to: UNSET, from: UNSET, append: UNSET,
                            increment: UNSET, decrement: UNSET, multiply: UNSET, clamp: UNSET, remove: UNSET)
          to = positional_to if to.equal?(UNSET) && !positional_to.equal?(UNSET)
          set_source = to.equal?(UNSET) ? from : to

          named = { set: set_source, append: append, increment: increment, decrement: decrement,
                    multiply: multiply, clamp: clamp, remove: remove }
                  .reject { |_, source| source.equal?(UNSET) }

          if named.empty?
            raise Malformed,
                  "#{@name}'s then_set :#{target} names no operation — " \
                  "give it to:, append:, increment:, decrement:, multiply:, clamp:, or remove:"
          end

          if named.size > 1
            raise Malformed,
                  "#{@name}'s then_set :#{target} tries to #{named.keys.join(' and ')} " \
                  "at once — one mutation, one meaning"
          end

          op, source = named.first
          @mutations << Mutation.new(target: target.to_sym, op: op, source: normalize_append_source(op, source))
        end

        # `append:` NORMALLY binds several fields at once (`append: {
        # name: :name, amount: :amount }`) — `Mutation#appended_fields`/
        # `MutationApplier#appended`/the meta-validator Judge's own
        # `mutation_rows` all read `mutation.source` as a Hash
        # unconditionally. A BARE value (`append: :single_field`, or any
        # non-Hash literal) is the one-field shorthand: exactly what an
        # explicit `append: { value: :single_field }` would have meant,
        # named the same way a single-field value object's own implicit
        # member already is (`MutationApplier#appended`'s own `:value`
        # scalar-unwrap). Without this, that shorthand built a Mutation
        # whose `source` was a bare Symbol, which crashed with a raw
        # `NoMethodError` on `#transform_values` the moment anything
        # downstream read it — at dispatch (`MutationApplier#appended`),
        # at IR emission (`Mutation#appended_fields`), and in the
        # meta-validator's own Judge (`Readings#mutation_rows`). #138.
        def normalize_append_source(op, source)
          return source unless op == :append
          return source if source.is_a?(::Hash)

          { value: source }
        end
      end
    end
  end
end
