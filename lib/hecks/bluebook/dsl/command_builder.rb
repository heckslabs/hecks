require_relative "word_gate"
require_relative "need_word"
require_relative "command_builder/owner"
require_relative "command_builder/rules"
require_relative "command_builder/mutations"
require_relative "command_builder/implicit_attributes"
require_relative "command_builder/operands"
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
        include NeedWord
        include ImplicitAttributes
        include Operands

        # Sentinel for "this keyword was never passed" — distinct from Ruby's own
        # nil/false, so `to: false` doesn't get treated as absent.
        UNSET = Object.new.freeze
        private_constant :UNSET

        # @param name [String] the command's name
        # @param from [String, Symbol, Array<String, Symbol>, nil] the lifecycle state(s) this
        #   command guards from
        # @param context [Hash] what the command reaches on its owner: `owner:`, `named_givens:`,
        #   `owner_attributes:`, `owner_constructs:` and `entity_shared_givens:` (see `Owner`)
        # @raise [ArgumentError] on any other keyword
        def initialize(name, from: nil, **context)
          @name      = name
          @givens    = []
          @ensures   = []
          @needs     = []
          @mutations = []
          @emits     = []
          adopt_owner(Owner.from(**context))
          @from = normalize_from(from)
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
          refuse_mixed_delegation!

          Command.declare(**declared_rules, **declared_effects)
        end

        # Evaluates a `command` block against a fresh builder and returns what it built.
        #
        # @param name [String] the command's name
        # @param from [String, Symbol, Array<String, Symbol>, nil] the lifecycle state(s) this
        #   command guards from
        # @param context [Hash] what the command reaches on its owner (see `#initialize`)
        # @yield the command body, evaluated with the builder as `self`; may be omitted
        # @return [Bluebook::Command] the built command
        # @raise [Bluebook::DSL::Malformed] if the body fails any check `#build` raises
        def self.build(name, from: nil, **context, &block)
          builder = new(name, from: from, **context)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        def adopt_owner(owner)
          @owner            = owner.owner
          @named_givens     = owner.named_givens
          @owner_attributes = owner.owner_attributes
          @owner_constructs = owner.owner_constructs
          # The aggregate-wide cross-entity pool — see
          # `AggregateBuilder#entity`'s own comment and `EntityBuilder#
          # given`'s. Empty (never populated) for an aggregate-owned
          # command, which already checks its own owner's `named_givens`
          # directly and has no siblings to reach across; real only for
          # an entity-owned command's own bare reference.
          @entity_shared_givens = owner.entity_shared_givens
        end

        # Normalized the exact same way `StateTransition#from` already
        # is — one state or several, a single spelling either way,
        # both read back through `Array(...)` at check time.
        def normalize_from(from)
          case from
          when Array then from.map(&:to_s)
          when nil   then nil
          else            from.to_s
          end
        end

        def cross_reference(target, as, optional: false)
          attribute_impl(as || default_reference_name(target), Reference.new(target), optional: optional)
        end

        def refuse_mixed_delegation!
          delegation = @mutations.find { |mutation| mutation.op == :delegate }
          return unless delegation && (@mutations.size > 1 || @emits.any?)

          raise Malformed,
                "#{@name} both delegates_to #{delegation.target} and declares its own " \
                "sets/emits — a delegating command is a pure passthrough (see delegates_to's " \
                "own comment); its result is the delegated command's own"
        end

        def declared_rules
          { name: @name, role: @role, goal: @goal, attributes: attributes, givens: @givens,
            ensures: @ensures, needs: @needs }
        end

        def declared_effects
          { mutations: @mutations, emits: @emits, references: @references, from: @from,
            provenance: @provenance }
        end
      end
    end
  end
end
