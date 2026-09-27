require_relative "traits"

module Hecks
  module Bluebook
    module Behaviour
      # **What a command does**. Extended, not included: a command is a class per verb.
      module Command
        include Indexed

        # Indexes the attributes once; they are final once absorbed.
        #
        # @return [Class] self — the command class, once its attributes are
        #   indexed
        def settle
          index_attributes(@attributes)
          self
        end

        # The construct this verb acts upon — the construct itself, not its name.
        #
        # A verb declared on an entity always acts on that piece. It never
        # self-references, so `creates?` is true for it and cannot decide this alone.
        # A creating command on an aggregate acts on nothing yet, so nil.
        #
        # @return [Class, Bluebook::Aggregate, nil] the entity class (a
        #   `Bluebook::Entity` subclass) this verb acts on when declared on an
        #   entity, the aggregate instance when declared on an aggregate and
        #   non-creating, or `nil` for a creating command
        def acts_on
          # Fully qualified: a bare `Entity` here resolves to Behaviour::Entity, not the construct.
          return hecks_owner if hecks_owner.is_a?(Class) && hecks_owner < Bluebook::Entity

          creates? ? nil : hecks_owner
        end

        # Whether this command creates a new root rather than acting on one.
        #
        # @return [Boolean] whether this command creates a new root — true when
        #   it declares no `reference_to` back to its own owner
        def creates? = @references.nil?

        # Every reason this verb can refuse on a rule: the descriptions of its givens and
        # ensures, as the runtime quotes them after "refused — ". Unnamed rules are skipped.
        #
        # @return [Array<String>] every named given's and ensure's own
        #   description text, skipping unnamed rules
        def guard_descriptions = (@givens + @ensures).map(&:description).compact

        # The argument name that addresses an instance of `aggregate_name` for this command.
        #
        # Self-addressing commands (`references == aggregate_name`) use the bare reference
        # key. Cross-referencing ones use the declared reference attribute's own name, never
        # re-derived from the target, since `as:` names can differ.
        #
        # @param aggregate_name [String, Symbol] the aggregate a fan-out dispatch is
        #   addressing an instance of
        # @return [String, nil] the argument name that addresses it, or nil if this command
        #   cannot be addressed by a row of that aggregate
        def addressing_key_for(aggregate_name)
          return Naming.reference_key(aggregate_name) if references.to_s == aggregate_name.to_s

          attributes.find { |attribute| attribute.reference? && attribute.type.target_name.to_s == aggregate_name.to_s }
                    &.name
        end
      end

      # **A mutation's own readings**. Included, not extended: Mutation is a Struct.
      module Mutation
        # An append binds several fields at once, each from a command argument (a Symbol)
        # or a literal, spelled through `Literal.render`.
        #
        # @return [Hash{Symbol => String}] the append's field bindings, each
        #   value rendered through `Literal.render`
        def appended_fields = source.transform_values { |value| Literal.render(value) }

        # Classifies this mutation's source for the wire, the counterpart
        # `Assembly::Marks#classified` reads back.
        #
        # @return [Hash{Symbol => Object}] `{kind: "argument", name:}` for a
        #   command argument, `{kind: "state", name:}` for a state
        #   self-reference, or `{kind: "literal", value:}` for a literal value
        def classified_source
          if source.is_a?(Symbol)
            { kind: "argument", name: source.to_s }
          elsif source.is_a?(StateRef)
            { kind: "state", name: source.name.to_s }
          else
            { kind: "literal", value: source }
          end
        end
      end
    end
  end
end
