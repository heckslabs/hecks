module Hecksagain
  class Bluebook
    module DSL
      class CommandBuilder
        include AttributeCollector

        # Vendored addition, not (yet) upstream hecksagain (migration plan
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

        def initialize(name, owner: nil)
          @name      = name
          @owner     = owner
          @givens    = []
          @ensures   = []
          @mutations = []
          @emits     = []
        end

        # A command carries ONE responsibility role — the language never
        # declared an OR between two roles, so a second `role` call would
        # otherwise silently win while the first still looked declared,
        # exactly the failure mode `reference_to`'s own duplicate guard
        # (below) already exists to prevent for a command's root.
        def role(value)
          raise Malformed,
                "#{@name} declares role twice — a command carries ONE " \
                "responsibility; the second would silently win and the " \
                "first would still look declared" if @role

          @role = value
        end

        def goal(value) = @goal = value

        # See AggregateBuilder#provenance's own comment — identical shape,
        # one level down.
        def provenance(from:) = @provenance = from

        # `optional:` rides here as well as on a plain attribute : `as:` makes a
        # reference into a NAMED ARGUMENT, and a named argument is exactly the kind
        # of fact that may or may not be given. The meta-domain's Verb.Declare
        # points at the Entity a command belongs to — and most commands belong to no
        # entity at all.
        def reference_to(type, as: nil, optional: false)
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
          attribute(as || :"#{Naming.snake(target)}_id", Reference.new(target), optional: optional)
        end

        public

        def given(description, &predicate)
          canonical = Ports::Extraction.canonical(predicate)

          # moved to the language: given "a rule says what it means", on Verb.Rule

          if canonical.to_s.empty?
            raise Malformed,
                  "#{@name}'s given #{description.inspect} did not survive " \
                  "extraction — its source could not be read, so no other " \
                  "runtime could ever evaluate it"
          end

          @givens << Given.new(
            description: description,
            canonical:   canonical,
            predicate:   predicate
          )
        end

        # The POSTCONDITION — a given for the far side of the mutations,
        # evaluated against the settled record with `old` naming the state
        # as it stood before them: `ensures("...") { old.balance.cents ==
        # balance.cents + amount.cents }`. Same extraction, same Rule
        # shape, same refusal form; EnsuresNotMet instead of GivenNotMet.
        def ensures(description, &predicate)
          canonical = Ports::Extraction.canonical(predicate)

          if canonical.to_s.empty?
            raise Malformed,
                  "#{@name}'s ensures #{description.inspect} did not survive " \
                  "extraction — a postcondition is carried as text, and this " \
                  "one has none"
          end

          @ensures << Given.new(
            description: description,
            canonical:   canonical,
            predicate:   predicate
          )
        end

        # `sets` is the word; `then_set` is the spelling every existing
        # bluebook was written under (Syntax::Keyword carries the rename as
        # `was:`), and it stays answered here forever — a renamed word's old
        # era keeps booting, which is the whole point of the rename column.
        #
        # Vendored addition, not (yet) upstream hecksagain: `then_set
        # :target, from: :source_field` (hecks_conception/miette, found
        # live in body/doctor/bluebook/doctor.bluebook) -- semantically
        # identical to `to:` (copy this argument/field into the target),
        # different word. TODO upstream via bin/evolve (migration plan
        # task 7): decide whether `from:` or `to:` becomes the canonical
        # spelling.
        #
        # Vendored addition, not (yet) upstream hecksagain (migration plan
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
        # `remove:` -- vendored addition, not (yet) upstream hecksagain
        # (migration plan task 4): the list-removal counterpart to
        # `append:` (plan.bluebook's own RemoveDependency/DeactivateSprint
        # commands: "the runtime list-remove primitive (then_set remove:)
        # drops it from the list element-wise, with no read-modify-write
        # -- so a concurrent Add can never be lost"). Matches an element
        # by VALUE equality against `mutation.source` (resolved and
        # Value-coerced the same way increment/decrement/multiply already
        # coerce their own amount -- see MutationApplier#removed).
        #
        # `then_set :field, true` -- vendored addition, not (yet) upstream
        # hecksagain (migration plan task 8): a bare positional literal
        # instead of `to:` -- 14 occurrences across hecks_nursury
        # (oceanography.bluebook/volcanology.bluebook and others),
        # always a boolean shorthand (`then_set :deployed, true`, never
        # a string/number positional -- checked directly, zero non-
        # boolean occurrences of the bare-positional-second-arg shape
        # anywhere in the corpus). Folded into `to:` itself rather than
        # given its own mutation op -- semantically identical, same
        # UNSET-sentinel discipline the `to: false` fix already
        # established (a positional `false` must read as "set to
        # false," not "absent," same as the keyword form). Only applied
        # when `to:` itself was NOT also given, so an explicit `to:`
        # keyword always wins over a stray positional.
        def then_set(target, positional_to = UNSET, to: UNSET, from: UNSET, append: UNSET,
                     increment: UNSET, decrement: UNSET, multiply: UNSET, clamp: UNSET, remove: UNSET)
          # moved to the language: given "a mutation names a target", on Verb.Change

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
          @mutations << Mutation.new(target: target.to_sym, op: op, source: source)
        end
        alias_method :sets, :then_set

        # No raise here. "an event is named" is declared in the language itself —
        # language/bluebook/behavior.bluebook, on Command.Announce — and MetaValidator is what
        # enforces it. This is the first rule to move ACROSS rather than be
        # duplicated : delete the declaration and an unnamed event is accepted,
        # which is what makes the meta-domain load-bearing rather than decorative.
        def emits(event_name)
          @emits << event_name.to_s
        end

        def build
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
            provenance: @provenance
          )
        end

        def self.build(name, owner: nil, &block)
          builder = new(name, owner: owner)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
