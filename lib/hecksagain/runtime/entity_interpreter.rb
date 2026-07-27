# EntityInterpreter — the command machinery, ONE ELEMENT DEEP.
#
# An entity is addressed THROUGH its parent, never around it — the three-part
# verb the Entity IR documented from the day it was written:
#
#   dispatch("Banking::Account.LedgerEntry.Reverse", id: "acct-1", sequence: 2)
#
# Hydrate the PARENT, address ONE element of the list that holds this entity's
# records, gate its own lifecycle, mutate THAT element, save the parent. The
# event rides the parent's name, because outside the boundary the parent is
# the only addressable thing.
#
# ONE DELIBERATE DIVERGENCE FROM HECKS, recorded where it is visible : hecks
# runs an entity command against the PARENT record ("entities live within the
# parent's record"), which would write Reverse's narrative onto the Account
# itself. Undoing ONE movement is what the domain declares, so here the
# command addresses the element by the entity's own identified_by.
#
# The guard, the lifecycle rule and emit are CALLED on the CommandInterpreter
# rather than copied : "the exact machinery of dispatch" stops being true the
# moment there are two copies of it.
#
#   EntityInterpreter.new(registry, commands: ci).call(domain, aggregate, dotted, args)
#   # => [parent_instance, events]

module Hecksagain
  module Runtime
    class EntityInterpreter
      attr_reader :registry

      def initialize(registry, commands:)
        @registry = registry
        @commands = commands
      end

      def call(domain, aggregate, dotted, args)
        entity_name, command_name = dotted.split(".", 2)
        entity  = aggregate.entities.find { |e| e.name == entity_name } ||
                  raise(UnknownVerb, "#{aggregate.name} has no entity #{entity_name.inspect}")
        command = entity.command(command_name) ||
                  raise(UnknownVerb, "#{entity_name} has no command #{command_name.inspect}")

        repository = @registry.repository(domain, aggregate)
        instance   = parent(repository, aggregate, entity_name, command_name, args)
        element    = element_of(aggregate, entity, entity_name, command_name, instance, args)

        view = Instance.new(aggregate: entity, id: element[entity.identified_by].to_s, state: element)
        @commands.enforce_givens(view, command, args)
        transition = @commands.admissible_transition(entity, command, view)
        command.mutations.each { |mutation| apply_to_element(element, mutation, args) }
        element[entity.lifecycle.field] = transition.target if transition

        repository.save(instance)

        [instance, @commands.emit(command, domain, aggregate, instance, args, repository)]
      end

      private

      def parent(repository, aggregate, entity_name, command_name, args)
        parent_id = args[aggregate.identified_by] || args[:id] ||
                    raise(NotFound, "#{command_name} acts on a #{aggregate.name}'s #{entity_name} — pass #{aggregate.identified_by}:")
        repository.find(parent_id) ||
          raise(NotFound, "no #{aggregate.name} with #{aggregate.identified_by} #{parent_id.inspect}")
      end

      def element_of(aggregate, entity, entity_name, command_name, instance, args)
        list_attr = aggregate.attributes.find { |a| a.list? && a.type.to_s == entity_name } ||
                    raise(UnknownVerb, "#{aggregate.name} holds no list of #{entity_name}")
        key  = entity.identified_by
        want = args[key] ||
               raise(NotFound, "#{command_name} acts on one #{entity_name} — pass #{key}:")

        Array(instance[list_attr.name]).find { |el| el[key] == want } ||
          raise(NotFound, "no #{entity_name} with #{key} #{want.inspect} on #{aggregate.name} #{instance.id.inspect}")
      end

      # then_set on an element. Values store RAW — the append path stores an
      # element's fields as they arrive, and one entry VO-wrapped by a later
      # Reverse beside ten raw siblings would be two shapes for one column.
      # (VO construction for elements, both paths at once, is a named
      # follow-up on DESIGN-banking-exact.)
      def apply_to_element(element, mutation, args)
        case mutation.op
        when :set
          element[mutation.target] = @commands.resolve_source(mutation.source, args)
        when :increment, :decrement
          # The same Integer-or-nothing rule as `arithmetic` — an element's
          # count drifting on a coerced word is the same disease one level
          # down.
          amount  = @commands.resolve_source(mutation.source, args)
          op      = mutation.op.to_s
          current = element[mutation.target] || 0
          raise TypeMismatch, "#{op} of #{mutation.target} needs an Integer, got #{amount.inspect}" unless amount.is_a?(Integer)
          raise TypeMismatch, "#{op} of #{mutation.target} needs an Integer #{mutation.target}, got #{current.inspect}" unless current.is_a?(Integer)

          element[mutation.target] = current + (mutation.op == :increment ? amount : -amount)
        end
      end
    end
  end
end
