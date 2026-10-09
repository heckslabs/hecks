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
          ir = Build.call("Aggregate", @row, **built_children)

          stamp_references(ir)
          ir
        end

        private

        # The children `Build` cannot derive from the row alone, already built.
        def built_children
          {
            value_objects:     build_all("ValueObject", @row[:value_objects]),
            commands:          build_all("Command", @row[:commands]),
            entities:          Array(@row[:entities]).map { |piece| entity(piece) },
            queries:           build_all("Query", @row[:queries]),
            lifecycle:         lifecycle_of(@row),
            # Policies live on the chapter, which is what `PolicyInterpreter` reads.
            policies:          [],
            reference_targets: reference_targets(Array(@row[:attributes]).map { |field| Marks.attribute(field) })
          }
        end

        def build_all(category, rows)
          Array(rows).map { |row| Build.call(category, row) }
        end

        # Read from attributes, not commands: a command's self-references are not targets.
        def reference_targets(fields)
          fields.select(&:reference?).map { |field| field.type.target_name }
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

        # Folds `state_field`, `state_start`, `transitions` and `marks` into the IR's one Lifecycle.
        def lifecycle_of(row)
          declared = row[:lifecycle]
          return nil unless declared

          Lifecycle.new(
            field:       declared[:field],
            default:     declared[:default],
            transitions: transitions(Array(declared[:transitions])),
            marks:       marks(Array(declared[:marks]))
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

        # Regroups the one-row-per-state marks back into `name => states`, in declared order.
        def marks(rows)
          rows.group_by { |held| held[:name].to_s }.transform_values { |held| held.map { |row| row[:state].to_s } }
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
