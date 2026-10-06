require_relative "../errors"
require_relative "../refusal_wording"

module Hecks
  module Runtime
    class EntityInterpreter
      # A dotted entity verb resolved against its aggregate: the entity
      # chain it names and the command located at the end of it.
      Resolution = Data.define(:entity_names, :chain, :command_name, :command) do
        # Resolves a dotted entity verb into its entity chain and command,
        # raising UnknownVerb if either segment doesn't exist.
        def self.of(aggregate, dotted)
          *entity_names, command_name = dotted.to_s.split(".")
          if entity_names.empty?
            raise UnknownVerb, RefusalWording.render_site("UnknownVerb", "entity_unknown",
                                                          aggregate: aggregate.hecks_name, entity: dotted.to_s)
          end

          chain = walk(aggregate, entity_names)
          command = chain.last.command(command_name) ||
                    raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "entity_no_command",
                                                                  entity: chain.last.hecks_name, command: command_name))
          new(entity_names: entity_names, chain: chain, command_name: command_name, command: command)
        end

        # Walks one hop per dotted segment, resolving each entity name off
        # the previous one — not limited to two levels.
        def self.walk(aggregate, entity_names)
          owner = aggregate
          entity_names.map do |name|
            found = owner.entities.find { |piece| piece.hecks_name == name } ||
                    raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "entity_unknown",
                                                                  aggregate: owner.hecks_name, entity: name))
            owner = found
            found
          end
        end
        private_class_method :walk
      end
    end
  end
end
