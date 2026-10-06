module Hecks
  module Bluebook
    module DSL
      class BluebookBuilder
        module Validation
          # Checks of how a chapter's aggregates point at each other: the chapter's own namespace,
          # entity commands that root on themselves, and reference rings.
          module References
            private

            # A chapter's constants install under its name, or its `namespace`; landing in the
            # gem's own `Hecks` module would shadow the gem's modules (ADR 0080), so it refuses.
            def validate_not_the_gem_module!(bluebook)
              return unless (bluebook.namespace || bluebook.name) == "Hecks"

              raise Malformed, "#{bluebook.name}'s constants would install in the gem's own Hecks module — " \
                               "declare a namespace, such as namespace \"Hecks::Domain\", or rename the chapter"
            end

            # Refuses an entity command that names its own entity as its root.
            # `CommandBuilder#reference_to` sets `references` only to the owner's bare name, so on
            # an aggregate command a head lookup is a tautology; only an entity self-reference
            # fails.
            def validate_reference_value_objects!(aggregates)
              heads = aggregates.map(&:hecks_name)
              violations = aggregates.flat_map { |aggregate| entity_root_violations(aggregate, heads) }
              return if violations.empty?

              raise Malformed,
                    "an entity command is addressed through its aggregate; #{violations.uniq.join("; ")}"
            end

            def entity_root_violations(aggregate, heads)
              aggregate.entities.flat_map do |entity|
                entity.commands.filter_map do |command|
                  next unless command.references && !heads.include?(command.references.to_s)

                  "#{aggregate.hecks_name}.#{entity.hecks_name}.#{command.hecks_name} names itself as its root"
                end
              end
            end

            # A reference ring means no aggregate in it is a consistency boundary. Checked at
            # chapter level because seeing a cycle needs every end declared (ADR 0025). Catches
            # any ring length; self-reference stays legal, and a cross-chapter target is a
            # dangling name, not an edge.
            def validate_no_bidirectional_references!(aggregates)
              cycle = find_reference_cycle(reference_edges(aggregates))
              return unless cycle

              raise Malformed, reference_cycle_message(cycle)
            end

            def reference_edges(aggregates)
              aggregates.to_h do |aggregate|
                [aggregate.hecks_name, aggregate.reference_targets.uniq.reject { |target| target == aggregate.hecks_name }]
              end
            end

            def reference_cycle_message(cycle)
              ring = "#{cycle.join(" -> ")} -> #{cycle.first}"
              "reference cycle: #{ring} — an aggregate points at another by id, and a " \
                "ring back to where it started means no aggregate in it is a boundary " \
                "anyone can reason about alone ; break the ring, or let one side be found " \
                "through a query instead of a reference pointing back"
            end

            # Plain DFS with a visiting/done coloring; returns the ring in the order it
            # closes, or nil.
            def find_reference_cycle(edges)
              state = {}

              edges.each_key do |start|
                cycle = reference_cycle_from(start, edges, state, [])
                return cycle if cycle
              end

              nil
            end

            def reference_cycle_from(node, edges, state, path)
              return nil if state[node] == :done
              return path[path.index(node)..] if state[node] == :visiting

              state[node] = :visiting
              path.push(node)

              found = first_cycle_through(edges[node], edges, state, path)
              return found if found

              path.pop
              state[node] = :done
              nil
            end

            def first_cycle_through(targets, edges, state, path)
              targets.each do |target|
                # a name this chapter never declares is dangling, not an edge
                next unless edges.key?(target)

                found = reference_cycle_from(target, edges, state, path)
                return found if found
              end

              nil
            end
          end
        end
      end
    end
  end
end
