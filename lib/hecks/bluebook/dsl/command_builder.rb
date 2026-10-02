require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # The `command "Name" do ... end` receiver: collects role/goal/given/ensures/sets/
      # emits/delegates_to/corrects declarations and builds the final `Command`.
      class CommandBuilder
        GRAMMAR_CONTEXT = "Command".freeze

        include AttributeCollector
        include RuleReference
        include WordGate

        # Sentinel for "this keyword was never passed" — distinct from Ruby's own
        # nil/false, so `to: false` doesn't get treated as absent.
        UNSET = Object.new.freeze
        private_constant :UNSET

        def initialize(name, owner: nil, from: nil, named_givens: {}, owner_attributes: [], owner_constructs: [],
                       entity_shared_givens: {})
          @name              = name
          @owner             = owner
          @givens            = []
          @ensures           = []
          @needs             = []
          @mutations         = []
          @emits             = []
          @named_givens      = named_givens
          @owner_attributes  = owner_attributes
          @owner_constructs  = owner_constructs
          # The aggregate-wide cross-entity pool — see
          # `AggregateBuilder#entity`'s own comment and `EntityBuilder#
          # given`'s. Empty (never populated) for an aggregate-owned
          # command, which already checks its own owner's `named_givens`
          # directly and has no siblings to reach across; real only for
          # an entity-owned command's own bare reference.
          @entity_shared_givens = entity_shared_givens
          # Normalized the exact same way `StateTransition#from` already
          # is — one state or several, a single spelling either way,
          # both read back through `Array(...)` at check time.
          @from = case from
                  when Array then from.map(&:to_s)
                  when nil   then nil
                  else            from.to_s
                  end
        end

        # Sets the command's one responsibility role, refusing a second declaration.
        #
        # @param value [String, Symbol] the role's name
        # @return [Object] `value` as stored
        # @raise [Bluebook::DSL::Malformed] if a role is already declared
        def role_impl(value)
          if @role
            raise Malformed,
                  "#{@name} declares role twice — a command carries ONE " \
                  "responsibility; the second would silently win and the " \
                  "first would still look declared"
          end

          @role = value
        end

        # Sets the human-readable description shown for this command.
        #
        # @param value [String] the description text
        # @return [String] the description as stored
        def goal(value) = @goal = value

        # The outside facts a command may declare it needs, each the name of the attribute the
        # runtime fills when the caller leaves it out. `now` is the clock port's answer, in epoch
        # seconds.
        NEEDABLE_FACTS = %i[now].freeze

        # Declares an outside fact the runtime supplies before any given runs (ADR 0081):
        # `needs :now` fills the command's own `now` attribute from the clock port when the caller
        # names none.
        #
        # @param fact [Symbol] one of `NEEDABLE_FACTS`
        # @return [Array<Symbol>] the facts declared so far
        # @raise [Bluebook::DSL::Malformed] if the fact is not one the runtime can supply, or is
        #   declared twice
        def needs_impl(fact)
          fact = fact.to_sym
          unless NEEDABLE_FACTS.include?(fact)
            raise Malformed,
                  "#{@name} needs :#{fact}, which the runtime cannot supply — it supplies " \
                  "#{NEEDABLE_FACTS.map { |known| ":#{known}" }.join(', ')}"
          end
          raise Malformed, "#{@name} declares needs :#{fact} twice" if @needs.include?(fact)

          @needs << fact
        end

        # Names where a concept adopted from a canonical source came from.
        #
        # @param from [Object] the canonical source, captured exactly as written
        # @return [Object] `from` as stored
        def provenance_impl(from:) = @provenance = from

        # Declares the aggregate this command acts on (with no `as:`), or a cross-reference to
        # another aggregate (with `as:`).
        #
        # @param type [Module, Symbol, String] the referenced aggregate, written as a bare
        #   constant
        # @param as [Symbol, nil] the attribute's name for a cross-reference; nil declares the
        #   root this command acts on instead, unless `type` is a different aggregate than the
        #   owner
        # @param optional [Boolean] whether the reference may be absent
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if the command already acts on a root, or (for a
        #   cross-reference) `as` is already declared
        def reference_to_impl(type, as: nil, optional: false)
          demodulised = Naming.demodulise(type)

          # `as:` names an attribute, not "the root I act on" — without this check, a
          # command referencing its own aggregate type via `as:` would misread as a
          # second self-reference and be refused.
          return cross_reference(demodulised, as, optional: optional) if as || demodulised.to_s != @owner.to_s

          if @references
            raise Malformed,
                  "#{@name} references #{@owner} twice — a command acts on ONE " \
                  "root ; the second would silently win and the first would " \
                  "still look declared"
          end

          @references = demodulised
        end

        private

        def cross_reference(target, as, optional: false)
          attribute_impl(as || default_reference_name(target), Reference.new(target), optional: optional)
        end

        public

        # Declares a precondition this command requires, or references one the owning aggregate
        # (or a sibling piece) already declared.
        #
        # No block given means "use the one already declared" rather than a fresh rule (ADR 0025).
        #
        # @param description [String] the rule's description; also the name the owning
        #   aggregate's rule is referenced by when no block is given
        # @yield the predicate body; evaluated for its extracted source, never called directly
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if given a block whose source cannot be extracted, or
        #   given no block and the description names no precondition the owner (or a sibling
        #   piece under the same aggregate) declares
        def given_impl(description, &predicate)
          return reference_named_given(description) unless predicate

          @givens << build_rule(Given, description, predicate, owner_name: @name, word: "given",
                                 extraction_failure: "its source could not be read, so no other runtime could ever evaluate it")
        end

        private

        # Checks the command's own owner first, then — for a piece-owned command only —
        # a sibling piece's entity-level givens, since two pieces under the same
        # aggregate can share a precondition declared on just one of them.
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

        # Declares a postcondition, checked against the settled record after the command's own
        # mutations apply; `old` names the pre-mutation state.
        #
        # @param description [String] the rule's description
        # @yield the predicate body; evaluated for its extracted source, never called directly
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if the block's source could not be extracted
        def ensures(description, &predicate)
          @ensures << build_rule(Given, description, predicate, owner_name: @name, word: "ensures",
                                  extraction_failure: "a postcondition is carried as text, and this one has none")
        end

        # Maps each `sets` kwarg to the mutation op it selects. `to:` is the one kwarg
        # whose own name differs from the op it selects (`:set`); every other kwarg
        # selects the op of its own name.
        KWARG_TO_OP = { to: :set, append: :append, increment: :increment, decrement: :decrement,
                        multiply: :multiply, clamp: :clamp, remove: :remove }.freeze

        # Declares one mutation this command applies to `target`, its op selected by
        # whichever single keyword names a source; omitting all of them means `to: target`.
        #
        # @param to [Object] a Symbol equal to `target` is redundant and refused
        # @param clamp [Array(Object, Object)] the `[min, max]` pair to bound the current value to
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if `to:` redundantly repeats `target`, or more than
        #   one op-selecting keyword is given
        def sets_impl(target, positional_to = UNSET, to: UNSET, append: UNSET,
                      increment: UNSET, decrement: UNSET, multiply: UNSET, clamp: UNSET, remove: UNSET)
          to = positional_to if to.equal?(UNSET) && !positional_to.equal?(UNSET)

          # Only a Symbol can repeat the target's name; a literal value (`to: false`,
          # a String, ...) never has `.to_sym` to compare in the first place.
          if to.is_a?(Symbol) && to == target.to_sym
            raise Malformed,
                  "#{@name}'s sets :#{target}, to: :#{target} repeats the target — " \
                  "sets :#{target} alone already means the same"
          end

          given = { to: to, append: append, increment: increment, decrement: decrement,
                    multiply: multiply, clamp: clamp, remove: remove }
                  .reject { |_, source| source.equal?(UNSET) }
          named = given.to_h { |kwarg, source| [KWARG_TO_OP.fetch(kwarg), source] }

          # No operation named at all (not even bare `to:`) means `sets :field` alone.
          named = { set: target } if named.empty?

          if named.size > 1
            raise Malformed,
                  "#{@name}'s sets :#{target} tries to #{named.keys.join(' and ')} " \
                  "at once — one mutation, one meaning"
          end

          op, source = named.first
          @mutations << Mutation.new(target: target.to_sym, op: op, source: normalize_append_source(op, source))
        end

        # Refuses the `then_set` spelling outside shadow-parsing; while shadow-parsing frozen
        # era text, reads it via `legacy_then_set` instead.
        #
        # @param target [Symbol, String] the field this mutation writes
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] outside shadow-parsing, always; under
        #   shadow-parsing, if `legacy_then_set` names no operation or more than one
        def then_set_impl(target, positional_to = UNSET, **)
          return legacy_then_set(target, positional_to, **) if MetaValidator.shadow_parsing?

          raise Malformed, "#{@name}'s then_set is gone — sets is the word now"
        end

        # Declares one event this command announces to the outside. Accepts both quoted
        # text and a bare constant (`emits Account::AccountFrozen`); refusing the quoted
        # form is not yet safe since not every live bluebook has migrated off it.
        #
        # @param event_name [String, Symbol, Module] the event, quoted text or a bare constant
        # @return [Array<String>] every event declared so far, this one last
        def emits(event_name)
          @emits << Naming.event_ref(event_name)
        end

        # References the record's own current field as a mutation source, as opposed to a
        # bare Symbol, which names an argument, e.g. `sets :last, to: state(:current)`.
        #
        # @param name [Symbol, String] the field to read from the pre-dispatch record
        # @return [Literal::StateRef] the wrapped reference
        def state(name) = StateRef.new(name.to_sym)

        # Declares a synchronous, atomic delegation of this command's dispatch to one nested
        # entity command; unlike `trigger`/`saga`, the target's given/ensures are enforced as
        # real exceptions, so its refusal is the delegating command's own refusal too.
        #
        # @param target [String, Symbol] the delegated command, dotted `"Entity.Command"`
        # @param with [Hash{Symbol => Symbol, Object}] projects this command's own arguments
        #   onto the target's; a Symbol value names one of this command's own arguments,
        #   anything else is a literal
        # @return [Array<Bluebook::Mutation>] every mutation declared so far, this one last
        # @raise [Bluebook::DSL::Malformed] if `target` is not `"Entity.Command"` shaped
        def delegates_to_impl(target, with: {})
          entity_name, _dot, command_name = target.to_s.rpartition(".")
          if entity_name.empty? || command_name.empty?
            raise Malformed,
                  "#{@name}'s delegates_to #{target.inspect} does not name an entity and a command " \
                  "(\"Entity.Command\") — the same one-hop shape a bare given reference already uses"
          end

          @mutations << Mutation.new(target: target.to_s, op: :delegate, source: with)
        end

        # Declares that this command amends a past event, rather than rewriting it. `reverses:
        # true` auto-derives the corrective `sets` from the original event's own mutations,
        # and is mutually exclusive with an explicit `sets` on the same command.
        #
        # @param event [String, Symbol, Module] the event this command corrects
        # @param as [Symbol, nil] binds the located instance for a `given`/`ensures` to reference
        # @param reason [String, nil] why the correction is made, carried as audit data; required
        # @param reverses [Boolean] auto-derive the corrective `sets` from the original mutations
        # @return [Array<Bluebook::Mutation>] every mutation declared so far, this one last
        # @raise [Bluebook::DSL::Malformed] if `reason` is nil or blank
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

        # The effects that write a field of the record — `delegate` and
        # `corrects` name a command and an event, never a field.
        FIELD_EFFECTS = %i[set append remove increment decrement multiply clamp].freeze

        # Resolves implicit attributes, refuses conflicting mutations, and assembles the
        # declared rules and effects into a `Command`.
        #
        # @return [Bluebook::Command] the built command
        # @raise [Bluebook::DSL::Malformed] if the same field is written twice, an argument or
        #   state source names an undeclared field, or a delegating command also declares its
        #   own mutations or events
        def build
          resolve_implicit_attributes!
          refuse_duplicate_targets!
          refuse_undeclared_needs!

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
            needs:      @needs,
            mutations:  @mutations,
            emits:      @emits,
            references: @references,
            from:       @from,
            provenance: @provenance
          )
        end

        # A fact is filled into the argument of the same name, so the command declares one.
        #
        # @raise [Bluebook::DSL::Malformed] if a needed fact has no attribute to fill
        def refuse_undeclared_needs!
          declared = attributes.map { |attribute| attribute.name.to_s }
          missing  = @needs.reject { |fact| declared.include?(fact.to_s) }
          return if missing.empty?

          raise Malformed,
                "#{@name} needs :#{missing.first} but declares no attribute :#{missing.first} " \
                "for the runtime to fill — add `attribute :#{missing.first}, <type>`"
        end
        private :refuse_undeclared_needs!

        # Evaluates a `command` block against a fresh builder and returns what it built.
        #
        # @param name [String] the command's name
        # @param from [String, Symbol, Array<String, Symbol>, nil] the lifecycle state(s) this
        #   command guards from
        # @yield the command body, evaluated with the builder as `self`; may be omitted
        # @return [Bluebook::Command] the built command
        # @raise [Bluebook::DSL::Malformed] if the body fails any check `#build` raises
        def self.build(name, owner: nil, from: nil, named_givens: {}, owner_attributes: [], owner_constructs: [],
                       entity_shared_givens: {}, &block)
          builder = new(name, owner: owner, from: from, named_givens: named_givens,
                        owner_attributes: owner_attributes, owner_constructs: owner_constructs,
                        entity_shared_givens: entity_shared_givens)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # A command's effects are one update set over the pre-dispatch state — a field
        # written twice would make declaration order silently significant.
        def refuse_duplicate_targets!
          return if MetaValidator.shadow_parsing? # frozen era text is history

          seen = {}
          @mutations.each do |mutation|
            next unless FIELD_EFFECTS.include?(mutation.op)

            if (earlier = seen[mutation.target.to_sym])
              raise Malformed,
                    "#{@name} writes #{mutation.target} twice (#{earlier.op} and #{mutation.op}) — a command's " \
                    "effects are one update set over the pre-dispatch state, so each field is written at most once"
            end
            seen[mutation.target.to_sym] = mutation
          end
        end

        # `sets :field` alone already means the command accepts an argument named `:field` —
        # when the command hasn't declared its own `:field`, imports the owner's already-built
        # `Attribute` verbatim instead of requiring a redundant re-declaration (ADR 0025).
        # Requires the owner's own attributes to already exist by the time `build` runs.
        def resolve_implicit_attributes!
          @mutations.each do |mutation|
            case mutation.op
            when :set    then resolve_bare_set!(mutation)
            when :append then resolve_append_fields!(mutation)
            end
            refuse_unknown_state_sources!(mutation)
          end
          # A second, separate pass, not folded into the loop above: every mutation's own
          # self-referential import must land before any source is checked against the
          # final `attributes` list, or a legal declaration order gets refused.
          @mutations.each { |mutation| refuse_unknown_argument_sources!(mutation) }
        end

        # For exactly these ops, a bare Symbol source has exactly one legitimate reading —
        # a declared argument's name — since `append`'s record-state fallback doesn't apply
        # here; anything else would resolve to nil forever, indistinguishable from an
        # absent optional argument, unless refused explicitly.
        CHECKED_SYMBOL_SOURCE_OPS = %i[set increment decrement multiply remove].freeze
        private_constant :CHECKED_SYMBOL_SOURCE_OPS

        def refuse_unknown_argument_sources!(mutation)
          return unless CHECKED_SYMBOL_SOURCE_OPS.include?(mutation.op)
          return unless mutation.source.is_a?(Symbol)
          # The bare self-referential shape (`source == target`) is `resolve_bare_set!`'s
          # own territory — skipped here so an undeclared field is refused as a target
          # problem, not misreported as a source problem.
          return if mutation.source.to_s == mutation.target.to_s
          return if attributes.any? { |attr| attr.name == mutation.source }

          raise Malformed,
                "#{@name}'s sets :#{mutation.target} resolves :#{mutation.source} from its " \
                "arguments, but #{@name} declares no #{mutation.source} attribute — an " \
                "argument that does not exist resolves to nil, always, never what the " \
                "caller actually sent"
        end

        # `state(:name)` snapshots one of the owner's own fields; refused at build, the
        # same way an unknown `given` reference is.
        def refuse_unknown_state_sources!(mutation)
          sources = mutation.source.is_a?(Hash) ? mutation.source.values : [mutation.source]
          sources.grep(StateRef).each do |ref|
            next if @owner_attributes.any? { |attr| attr.name == ref.name }

            raise Malformed, "#{@name}'s sets :#{mutation.target} reads state(:#{ref.name}), " \
                             "which the owner does not declare"
          end
        end

        def resolve_bare_set!(mutation)
          # Only a Symbol naming its own target qualifies — a literal that merely spells the
          # same word (`sets :moved, to: "moved"`) must not import a phantom argument.
          return unless mutation.source.is_a?(Symbol) && mutation.source.to_s == mutation.target.to_s
          return if attributes.any? { |attr| attr.name == mutation.target }

          owner_attr = @owner_attributes.find { |attr| attr.name == mutation.target }
          attributes << owner_attr if owner_attr
        end

        # One hop deeper than `resolve_bare_set!`: an `append:` mutation builds a new list
        # element, so a bare self-referential field inside it resolves against the list's
        # own element type (`element_type_for`), not `@owner_attributes`.
        #
        # Position-preserving, not appended at the end — the exported IR is array-order-
        # sensitive, so resolved fields are reinserted at the position the group's leftmost
        # still-declared member already occupied.
        # rubocop:disable-next Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def resolve_append_fields!(mutation)
          return unless mutation.source.is_a?(Hash)

          element = element_type_for(mutation.target)
          return unless element

          self_ref_fields = mutation.source.select { |field, value| value.is_a?(Symbol) && value.to_s == field.to_s }.keys
          return if self_ref_fields.empty?

          present = self_ref_fields.filter_map { |field| attributes.find { |attr| attr.name == field } }
          # Already fully declared — nothing to resolve.
          return if present.size == self_ref_fields.size

          anchor = present.empty? ? attributes.length : present.map { |attr| attributes.index(attr) }.min
          attributes.reject! { |attr| present.include?(attr) }

          group = self_ref_fields.filter_map do |field|
            present.find { |attr| attr.name == field } || element.attributes.find { |attr| attr.name == field }
          end
          attributes.insert(anchor, *group)
        end

        # The owner's own list attribute names its element type as text; resolved against
        # `@owner_constructs` (the only two kinds an element can be) by `hecks_name`.
        def element_type_for(list_field)
          list_attr = @owner_attributes.find { |attr| attr.name == list_field && attr.list? }
          return nil unless list_attr

          @owner_constructs.find { |construct| construct.hecks_name.to_s == list_attr.type.to_s }
        end

        # Preserves `then_set`'s exact prior reading (`from:` a synonym for `to:`, no
        # omittable-`to:` shorthand) so frozen era text always re-parses to the same meaning.
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

        # `append:` normally binds a Hash of fields; a bare value (`append: :single_field`)
        # is the one-field shorthand for `append: { value: :single_field }` — without this,
        # downstream code that reads `mutation.source` as a Hash unconditionally would crash.
        def normalize_append_source(oper, source)
          return source unless oper == :append
          return source if source.is_a?(::Hash)

          { value: source }
        end
      end
    end
  end
end
