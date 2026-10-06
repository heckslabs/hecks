# frozen_string_literal: true

module Hecks
  module RustBuild
    module Coverage
      # The [kind, id] pairs a generated module's `ir.json` implies, independent of its manifest.
      module Expected
        module_function

        # @param payload [Hash] the parsed `ir.json`
        # @return [Array<Array(Symbol, String)>] every construct the IR declares, as [kind, id]
        def from_ir(payload)
          domain_name = payload.fetch(:name)
          expected = payload.fetch(:aggregates).flat_map { |aggregate| aggregate_constructs(domain_name, aggregate) }
          expected.concat(named_constructs(payload, domain_name))
          # An `ir.json` from before the `lineage` key existed has none: nothing to expect.
          payload.fetch(:lineage, {}).fetch(:capable_aggregates, []).each do |aggregate|
            expected << [:lineage_aggregate, "#{domain_name}::#{aggregate.fetch(:name)}"]
          end
          expected
        end

        # Read models, policies and process managers: constructs named directly under the domain.
        def named_constructs(payload, domain_name)
          { read_models: :read_model, policies: :policy, process_managers: :process_manager }.flat_map do |key, kind|
            payload.fetch(key).map { |entry| [kind, "#{domain_name}::#{entry.fetch(:name)}"] }
          end
        end

        # Entity-scoped query ids at any depth (`Domain::Aggregate.Entity.Query`); mirrors the
        # generator's own entity query entries.
        def entity_query_ids(owner_id, entities)
          entities.flat_map do |entity|
            entity_id = "#{owner_id}.#{entity.fetch(:name)}"
            entity.fetch(:queries, []).map { |q| "#{entity_id}.#{q.fetch(:name)}" } +
              entity_query_ids(entity_id, entity.fetch(:entities, []))
          end
        end

        def aggregate_constructs(domain_name, aggregate)
          id = "#{domain_name}::#{aggregate.fetch(:name)}"
          [[:aggregate, id]] + owned_constructs(id, aggregate) + entity_constructs(id, aggregate) +
            port_operations(id, aggregate)
        end

        def owned_constructs(id, aggregate)
          aggregate.fetch(:commands).map { |c| [:command, "#{id}.#{c.fetch(:name)}"] } +
            aggregate.fetch(:queries).map { |q| [:query, "#{id}.#{q.fetch(:name)}"] } +
            entity_query_ids(id, aggregate.fetch(:entities)).map { |query_id| [:query, query_id] }
        end

        def entity_constructs(id, aggregate)
          aggregate.fetch(:entities).flat_map do |entity|
            entity_id = "#{id}.#{entity.fetch(:name)}"
            [[:entity, entity_id]] +
              entity.fetch(:commands).map { |c| [:entity_command, "#{entity_id}.#{c.fetch(:name)}"] }
          end
        end

        def port_operations(id, aggregate)
          aggregate.fetch(:ports).flat_map do |port|
            port.fetch(:operations).map { |op| [:port_operation, "#{id}.#{port.fetch(:name)}.#{op.fetch(:name)}"] }
          end
        end
      end
    end
  end
end
