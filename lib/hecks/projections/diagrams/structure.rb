module Hecks
  module Projections
    module Diagrams
      # The diagrams of what a domain holds and connects: references between aggregates, who
      # issues each command, what each port exposes and what each read model is assembled from.
      module Structure
        module_function

        # `has_many`/`has_one` read from the owning side; `belongs_to`/`reference_to` read
        # from the target's side, since a bare reference does not promise uniqueness.
        #
        # @param bluebook [Bluebook::Chapter] the assembled chapter
        # @return [String, nil] the entity-relationship diagram, or nil without references
        def relationship_diagram(bluebook)
          edges = Diagrams.holders(bluebook).flat_map do |holder|
            holder.attributes.select(&:reference?).map { |attribute| relationship_edge(holder, attribute) }
          end
          return nil if edges.empty?

          subject = "#{bluebook.name}'s own declared reference_to/belongs_to/has_many/has_one attributes"
          "#{Diagrams.header(bluebook.name, subject)}erDiagram\n#{edges.join("\n")}\n"
        end

        def relationship_edge(holder, attribute)
          target = attribute.type.target_name
          case attribute.relationship
          when "has_many"
            %(    #{holder.hecks_name} ||--o{ #{target} : "#{attribute.name}")
          when "has_one"
            %(    #{holder.hecks_name} ||--#{attribute.optional? ? "o|" : "||"} #{target} : "#{attribute.name}")
          when "belongs_to", "reference_to"
            %(    #{target} #{attribute.optional? ? "|o" : "||"}--o{ #{holder.hecks_name} : "#{attribute.name}")
          end
        end

        # @param bluebook [Bluebook::Chapter] the assembled chapter
        # @return [String, nil] who issues which command, or nil when no command names a role
        def roles_diagram(bluebook)
          lines = Diagrams.holders(bluebook).flat_map do |holder|
            holder.commands.select(&:role).map { |command| role_edge(holder, command) }
          end
          return nil if lines.empty?

          Diagrams.flowchart(bluebook, "#{bluebook.name}'s own declared command roles", lines)
        end

        def role_edge(holder, command)
          %(    #{role_node(command.role)} -->|issues| #{Dispatch.command_node(holder.hecks_name, command.hecks_name)})
        end

        def role_node(role_name) = %(#{role_id(role_name)}((#{role_name})))

        # A role is free text ("Back office"), so only its id is sanitized; the label keeps
        # the text.
        def role_id(role_name) = "role_#{role_name.to_s.gsub(/[^A-Za-z0-9]+/, "_")}"

        # Walks `bluebook.aggregates`, not `holders`: an entity has no `ports` method.
        #
        # @param bluebook [Bluebook::Chapter] the assembled chapter
        # @return [String, nil] the port operations, or nil when no aggregate has a port
        def ports_diagram(bluebook)
          lines = bluebook.aggregates.flat_map do |holder|
            holder.ports.flat_map { |port| port.operations.map { |operation| port_edges(holder, port, operation) } }
          end.flatten
          return nil if lines.empty?

          subject = "#{bluebook.name}'s own declared port operations (which aggregate exposes each, its to:, and its emits)"
          Diagrams.flowchart(bluebook, subject, lines)
        end

        def port_edges(holder, port, operation)
          op = port_operation_node(holder.hecks_name, port.name, operation.hecks_name)
          edges = ["    #{holder.hecks_name}[(#{holder.hecks_name})] -.->|exposes| #{op}"]
          edges << "    #{op} -->|to: #{operation.to}| #{operation.to}[(#{operation.to})]" if operation.to
          operation.emits.each { |event| edges << "    #{op} -->|emits| #{Dispatch.event_node(event)}" }
          edges
        end

        def port_operation_node(aggregate_name, port_name, operation_name)
          id = "op_#{aggregate_name}_#{port_name}_#{operation_name}"
          %(#{id}[/"#{port_name}.#{operation_name}"/])
        end

        # @param bluebook [Bluebook::Chapter] the assembled chapter
        # @return [String, nil] each read model and its source aggregates, or nil without any
        def read_model_diagram(bluebook)
          lines = bluebook.read_models.flat_map { |read_model| read_model_edges(read_model) }
          return nil if lines.empty?

          subject = "#{bluebook.name}'s own declared read_models and the aggregates each is assembled from"
          Diagrams.flowchart(bluebook, subject, lines)
        end

        def read_model_edges(read_model)
          shape = read_model.to_h
          node = %(rm_#{shape[:name]}[["#{read_model_label(shape)}"]])
          Array(shape[:aggregate_heads]).map do |head|
            # Quoted because an unquoted `[` in an edge label (`accounts[]`) breaks Mermaid's
            # parser.
            label = head[:many] ? "#{head[:as]}[]" : head[:as]
            %(    #{head[:aggregate]}[(#{head[:aggregate]})] -->|"#{label}"| #{node})
          end
        end

        def read_model_label(shape)
          return "#{shape[:name]} (count)" if shape[:count]
          return "#{shape[:name]} (median: #{shape[:median_field]})" if shape[:median_field]

          shape[:name]
        end
      end
    end
  end
end
