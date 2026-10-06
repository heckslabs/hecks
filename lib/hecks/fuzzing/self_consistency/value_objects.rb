require "json"

module Hecks
  module Fuzzing
    module SelfConsistency
      # The value-object round trip: every value object a sequence built must survive
      # `to_json` then `Value.build`. Mixed into `SelfConsistency`.
      module ValueObjects
        # Every value object the sequence built must survive `to_json` then `Value.build`.
        #
        # The owning aggregate is passed to `build` so nested composite fields resolve; with `nil`
        # they come back as bare Hashes, a false positive. Query rows are skipped because they
        # name no single owning aggregate.
        def check_value_object_round_trip(history)
          value_objects_in(history).filter_map { |value, aggregate| round_trip_finding(value, aggregate) }
        end

        # Every `[value, owning aggregate]` pair found in the history's instances and events.
        def value_objects_in(history)
          bluebooks = history[:bluebooks] || {}
          seen = {}.compare_by_identity
          found = []

          history[:instances].each do |key, state|
            walk_value_objects(state, found, seen, instance_owner(bluebooks, key))
          end

          history[:events].each do |event|
            walk_value_objects(event[:payload], found, seen, owning_aggregate(bluebooks, event[:aggregate].to_s))
          end

          found
        end

        # The aggregate a stored-record key `Domain::Aggregate#id` belongs to, or nil.
        def instance_owner(bluebooks, key) = owning_aggregate(bluebooks, key.to_s.split("#", 2).first.to_s)

        # The aggregate a `"Domain::Aggregate"` name refers to, or nil.
        def owning_aggregate(bluebooks, qualified_name)
          domain_name, aggregate_name = qualified_name.split("::", 2)
          bluebooks[domain_name]&.aggregate(aggregate_name)
        end

        # The finding for one value that does not survive its round trip, or nil.
        def round_trip_finding(value, aggregate)
          rebuilt, error = rebuild(value, aggregate)
          if error
            return { field: "value_object_round_trip", type: value.type_name, original: value.to_h,
                     error: "#{error.class}: #{error.message}" }
          end
          return if rebuilt == value

          { field: "value_object_round_trip", type: value.type_name, original: value.to_h,
            rehydrated: rebuilt.to_h }
        end

        # `[rebuilt value, nil]`, or `[nil, the error]` when the rebuild raises.
        def rebuild(value, aggregate)
          [Runtime::Value.build(value.value_object, JSON.parse(value.to_json), aggregate), nil]
        rescue StandardError => e
          [nil, e]
        end

        # Recurses via `#[]` rather than `#to_h`, which would materialize nested values away.
        # `seen` compares by identity: a live state and an event payload can share one object,
        # while two equal but distinct value objects are still two round trips to prove.
        def walk_value_objects(node, found, seen, aggregate)
          case node
          when Runtime::Value then walk_value_object(node, found, seen, aggregate)
          when Hash           then node.each_value { |value| walk_value_objects(value, found, seen, aggregate) }
          when Array          then node.each { |value| walk_value_objects(value, found, seen, aggregate) }
          end
        end

        def walk_value_object(node, found, seen, aggregate)
          return if seen[node]

          seen[node] = true
          found << [node, aggregate]
          node.value_object.attributes.each do |attribute|
            walk_value_objects(node[attribute.name], found, seen, aggregate)
          end
        end
      end
    end
  end
end
