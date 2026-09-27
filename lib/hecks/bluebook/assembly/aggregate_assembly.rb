module Hecks
  module Bluebook
    class Assembly
      # Builds one aggregate from its declaration: containment and reference resolution.
      class AggregateAssembly
        # @param row [Hash{Symbol => Object}] one declared aggregate's raw contract data,
        #   as `@declaration[:aggregates]` carries it
        def initialize(row)
          @row = row
        end

        # Builds the aggregate's whole owner-chain graph — its value objects, commands,
        # entities, queries and lifecycle — from its raw declaration.
        #
        # @return [Bluebook::Aggregate] the built aggregate, with every reference stamped
        #   to resolve against it
        def aggregate
          shapes   = Array(@row[:value_objects]).map { |shape| value_object(shape) }
          commands = Array(@row[:commands]).map { |verb| Build.call("Command", verb) }
          entities = Array(@row[:entities]).map { |piece| entity(piece) }
          asks     = Array(@row[:queries]).map { |ask| Build.call("Query", ask) }

          fields = Array(@row[:attributes]).map { |field| Marks.attribute(field) }

          ir = Build.call(
            "Aggregate", @row,
            value_objects:     shapes,
            commands:          commands,
            entities:          entities,
            queries:           asks,
            lifecycle:         lifecycle_of(@row),
            # Policies live on the chapter, which is what `PolicyInterpreter` reads.
            policies:          [],
            reference_targets: reference_targets(fields)
          )

          stamp_references(ir)
          ir
        end

        private

        # Read from attributes, not commands: a command's self-references are not targets.
        def reference_targets(fields)
          fields.select(&:reference?).map { |field| field.type.target_name }
        end

        def value_object(row)
          Build.call("ValueObject", row)
        end

        # Recurses, so entities nest to any depth (ADR 0026).
        def entity(row)
          Build.call(
            "Entity", row,
            commands:  Array(row[:commands]).map { |verb| Build.call("Command", verb) },
            queries:   Array(row[:queries]).map { |ask| Build.call("Query", ask) },
            entities:  Array(row[:entities]).map { |piece| entity(piece) },
            lifecycle: lifecycle_of(row)
          )
        end

        # Must cover every list that can carry a reference: a missed one resolves to nil,
        # and a nil target is skipped rather than refused.
        def stamp_references(aggregate)
          lists = [aggregate.attributes, *aggregate.commands.map(&:attributes), *aggregate.queries.map(&:attributes)]
          entity_reference_lists(aggregate.entities, lists)

          lists.flatten.select(&:reference?).each { |field| field.type.declared_in = aggregate }
        end

        def entity_reference_lists(entities, lists)
          entities.each do |piece|
            lists << piece.attributes
            lists.concat(piece.commands.map(&:attributes))
            lists.concat(piece.queries.map(&:attributes))
            entity_reference_lists(piece.entities, lists)
          end
        end

        # Folds `state_field`, `state_start` and `transitions` into the IR's one Lifecycle.
        def lifecycle_of(row)
          declared = row[:lifecycle]
          return nil unless declared

          Lifecycle.new(
            field:       declared[:field],
            default:     declared[:default],
            transitions: transitions(Array(declared[:transitions]))
          )
        end

        # Regroups `to_h` rows by command and target; grouping by command alone would fuse
        # declarations that move one verb to different states.
        def transitions(rows)
          rows.group_by { |move| [move[:command], move[:to_state]] }
              .map do |(command, target), moves|
                froms = moves.filter_map { |move| move[:from_state] }
                [command.to_s, StateTransition.new(target: target, from: from_of(froms))]
              end
        end

        def from_of(froms)
          return nil         if froms.empty?
          return froms.first if froms.size == 1

          froms
        end
      end
    end
  end
end
