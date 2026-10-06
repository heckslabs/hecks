require "json"

module Hecks
  module Fuzzing
    module DomainGenerator
      # The single removals a blueprint can be shrunk by.
      module Removals
        def removals(blueprint)
          paths = blueprint["policies"].each_index.map { |i| ["policies", i] }
          blueprint["aggregates"].each_with_index { |aggregate, a| paths.concat(aggregate_removals(aggregate, a)) }
          paths
        end

        def aggregate_removals(aggregate, index)
          at = ["aggregates", index]
          paths = index.positive? ? [at] : []
          paths.concat(member_removals(aggregate, at))
          paths.concat(attribute_removals(aggregate, at))
          aggregate["commands"].each_with_index { |command, i| paths.concat(command_removals(command, [*at, "commands", i])) }
          paths.concat(entity_removals(aggregate, at))
        end

        # Each query, invariant, entity and reference, then the lifecycle.
        def member_removals(aggregate, at)
          paths = %w[queries invariants entities references].flat_map do |key|
            aggregate[key].each_index.map { |i| [*at, key, i] }
          end
          aggregate["lifecycle"] ? paths << [*at, "lifecycle"] : paths
        end

        def attribute_removals(aggregate, at)
          aggregate["attributes"].each_with_index.filter_map do |attribute, i|
            [*at, "attributes", i] unless aggregate["identity"].include?(attribute["name"])
          end
        end

        def entity_removals(aggregate, at)
          aggregate["entities"].each_with_index.flat_map do |entity, e|
            paths = entity["lifecycle"] ? [[*at, "entities", e, "lifecycle"]] : []
            paths + entity["commands"].each_index.map { |i| [*at, "entities", e, "commands", i] }
          end
        end

        def command_removals(command, at)
          paths = command["creates"] ? [] : [at]
          command["givens"].each_index { |g| paths << [*at, "givens", g] }
          paths << [*at, "role"] if command["role"]
          paths << [*at, "emits", command["emits"].size - 1] if command["emits"].size > 1
          paths
        end

        def remove_at(blueprint, path)
          copy = JSON.parse(JSON.generate(blueprint))
          *parents, last = path
          holder = parents.empty? ? copy : copy.dig(*parents)
          holder.is_a?(Array) ? holder.delete_at(last) : holder.delete(last)
          copy
        end
      end
    end
  end
end
