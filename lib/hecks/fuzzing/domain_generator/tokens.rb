module Hecks
  module Fuzzing
    module DomainGenerator
      # The tokens a blueprint offers, which each element's `requires` is checked against.
      module Tokens
        def tokens(blueprint)
          blueprint["aggregates"].each_with_object(Set.new) { |aggregate, set| aggregate_tokens(aggregate, set) }
        end

        def aggregate_tokens(aggregate, set)
          name = aggregate["name"]
          set << "aggregate:#{name}"
          set << "lifecycle:#{name}" if aggregate["lifecycle"]
          aggregate["attributes"].each { |attribute| set << "attribute:#{name}.#{attribute["name"]}" }
          aggregate["references"].each { |target| set << "reference:#{name}->#{target}" }
          nested_tokens(name, aggregate, set)
        end

        def nested_tokens(name, aggregate, set)
          aggregate["commands"].each { |command| command_tokens(name, command, set) }
          aggregate["entities"].each { |entity| entity_tokens(name, entity, set) }
        end

        def command_tokens(name, command, set)
          set << "command:#{name}.#{command["name"]}"
          command["references"].each { |target| set << "command_reference:#{name}.#{command["name"]}->#{target}" }
          command["emits"].each { |event| set << "event:#{name}.#{event}" }
        end

        def entity_tokens(name, entity, set)
          set << "entity:#{name}.#{entity["name"]}"
          set << "lifecycle:#{name}.#{entity["name"]}" if entity["lifecycle"]
          entity["commands"].each { |command| set << "command:#{name}.#{entity["name"]}.#{command["name"]}" }
        end
      end
    end
  end
end
