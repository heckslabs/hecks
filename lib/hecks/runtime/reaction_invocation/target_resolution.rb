require_relative "../../naming"
require_relative "../errors"

module Hecks
  module Runtime
    module ReactionInvocation
      # Finds what a reaction's target verb names (an aggregate command, an entity command or a
      # port operation) and which receiver the triggering event can lend it. Extended onto
      # {ReactionInvocation}.
      module TargetResolution
        private

        def resolve_target(registry, verb)
          domain, aggregate_name, command_path = Naming.split_verb(verb)
          raise UnknownVerb, "reaction target #{verb.inspect} is not a qualified command" unless command_path

          aggregate = registry.bluebook(domain)&.aggregate(aggregate_name)
          raise UnknownVerb, "reaction target #{verb.inspect} does not resolve to an aggregate" unless aggregate

          *entity_names, command_name = command_path.split(".")

          # A port operation shares the two-segment tail shape an entity command
          # uses ("Head.Rest"); checked first, matching the order
          # `Dispatcher#dispatch` already resolves a live verb in.
          port_target(aggregate, entity_names, command_name, verb) ||
            entity_target(aggregate, entity_names, command_name, verb)
        end

        def port_target(aggregate, entity_names, command_name, verb)
          return unless entity_names.one? && (port = aggregate.port(entity_names.first))

          operation = port.operation(command_name)
          raise UnknownVerb, "reaction target #{verb.inspect} does not resolve to a declared port operation" unless operation

          Target.new(aggregate: aggregate, entities: [], command: operation)
        end

        def entity_target(aggregate, entity_names, command_name, verb)
          entities = entity_chain(aggregate, entity_names, verb)
          command  = (entities.last || aggregate).command(command_name)
          raise UnknownVerb, "reaction target #{verb.inspect} does not resolve to a command" unless command

          Target.new(aggregate: aggregate, entities: entities, command: command)
        end

        # The entities `entity_names` walks down from the aggregate, each owned by the one before.
        def entity_chain(aggregate, entity_names, verb)
          owner = aggregate
          entity_names.map do |entity_name|
            owner = owner.entities.find { |candidate| candidate.hecks_name == entity_name } ||
                    raise(UnknownVerb, "reaction target #{verb.inspect} does not resolve entity #{entity_name.inspect}")
          end
        end

        def command_facts(command, args)
          declared = command.attributes.map { |attribute| attribute.name.to_sym }
          args.slice(*declared)
        end

        def aggregate_aliases(target)
          aliases = [:aggregate, Naming.reference_key(target.aggregate.name)]
          aliases.unshift(target.command.addressing_key_for(target.aggregate.name)) if target.entities.empty?
          aliases.compact.uniq
        end

        # An event's own identity can supply the receiver of a non-creating command on
        # the same aggregate root; it never addresses another aggregate or an entity.
        def source_receiver_for(target, source_receiver)
          return nil unless source_receiver
          # `target.command.creates?` alone misreads every entity command, which always
          # answers true for `creates?` though it never creates anything (Behaviour::
          # Command#creates?) — checked as the same compound condition `build` uses below.
          return nil if target.entities.empty? && target.command.creates?

          source = source_receiver.transform_keys(&:to_sym)
          return nil unless same_aggregate?(target, source[:aggregate].to_s)

          identity = source[:identity]
          identity.to_s unless blank_identity?(identity)
        end

        def same_aggregate?(target, source_aggregate)
          source_aggregate == (source_aggregate.include?("::") ? target.aggregate.hecks_fqn : target.aggregate.hecks_name)
        end
      end
    end
  end
end
