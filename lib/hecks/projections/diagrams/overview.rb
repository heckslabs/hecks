module Hecks
  module Projections
    module Diagrams
      # The one-graph overview of a domain: every aggregate and the references between them,
      # each port as a boundary around the operations it exposes, each process manager with
      # the aggregates it dispatches to, and each read model with its sources.
      module Overview
        module_function

        # @param bluebook [Bluebook::Declaration] the assembled bluebook
        # @return [String, nil] the overview flowchart, or nil for a domain with no aggregate
        def diagram(bluebook)
          return nil if bluebook.aggregates.empty?

          lines = aggregate_lines(bluebook) + reference_lines(bluebook) + port_lines(bluebook) +
                  saga_lines(bluebook) + read_model_lines(bluebook)
          Diagrams.flowchart(bluebook, "#{bluebook.name}'s whole shape: aggregates, references, ports, " \
                                       "process managers and read models", lines + [PROCESS_STYLE])
        end

        # The one class a process manager carries, so sagas read apart from aggregates.
        PROCESS_STYLE = "    classDef process fill:#eef6ff,stroke:#4a7bd0".freeze

        def aggregate_lines(bluebook)
          bluebook.aggregates.map { |aggregate| "    #{cylinder(aggregate.hecks_name)}" }
        end

        def cylinder(name) = "#{name}[(#{name})]"

        # A reference reads from the holder to what it points at, labelled with the attribute.
        def reference_lines(bluebook)
          Diagrams.holders(bluebook).flat_map do |holder|
            holder.attributes.select(&:reference?).map do |attribute|
              "    #{holder.hecks_name} -->|#{attribute.name}| #{cylinder(attribute.target_name)}"
            end
          end
        end

        def port_lines(bluebook)
          bluebook.aggregates.flat_map do |holder|
            holder.ports.map { |port| port_boundary(holder, port) }
          end
        end

        # Each port is a subgraph, so its operations read as one interface and not as loose nodes.
        def port_boundary(holder, port)
          id = "port_#{holder.hecks_name}_#{port.name}"
          body = port.operations.flat_map { |operation| Structure.port_edges(holder, port, operation) }
          ["    subgraph #{id}[\"#{holder.hecks_name}.#{port.name}\"]", *body, "    end"]
        end

        # A process manager is a node the aggregates it dispatches to hang off, once each.
        def saga_lines(bluebook)
          bluebook.process_managers.flat_map do |saga|
            node = "saga_#{saga.hecks_name}"
            targets = saga.handlers.flat_map { |handler| handler.dispatches.map { |dispatch| target_of(dispatch) } }
            ["    #{node}{{\"#{saga.hecks_name}\"}}:::process",
             *targets.compact.uniq.map { |name| "    #{node} -->|dispatches| #{cylinder(name)}" }]
          end
        end

        # A command reads `Account.Open`; the aggregate is the part before the dot.
        def target_of(dispatch) = dispatch.command_name.to_s.split(".").first

        def read_model_lines(bluebook)
          bluebook.read_models.flat_map { |read_model| Structure.read_model_edges(read_model) }
        end
      end
    end
  end
end
