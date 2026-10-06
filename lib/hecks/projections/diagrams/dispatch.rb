module Hecks
  module Projections
    module Diagrams
      # The diagrams of what happens when something is called: the command-to-event-to-policy
      # flow, and each aggregate's surface of commands, mutations and queries.
      module Dispatch
        module_function

        # @param bluebook [Bluebook::Chapter] the assembled chapter
        # @return [String, nil] commands, the events they emit and the policies those trigger,
        #   or nil when there are none
        def dispatch_diagram(bluebook)
          lines = (command_edges(bluebook) + bluebook.policies.map { |policy| trigger_edge(policy) }).compact
          return nil if lines.empty?

          subject = "#{bluebook.name}'s own declared commands' emits and policies' on/trigger"
          Diagrams.flowchart(bluebook, subject, lines)
        end

        def command_edges(bluebook)
          Diagrams.holders(bluebook).flat_map do |holder|
            holder.commands.flat_map do |command|
              command.emits.map { |event| emits_edge(holder, command, event) }
            end
          end
        end

        def emits_edge(holder, command, event)
          %(    #{command_node(holder.hecks_name, command.hecks_name)} -->|emits| #{event_node(event)})
        end

        # `on_event` may be aggregate-qualified while `emits` never is, so match on the bare tail.
        def trigger_edge(policy)
          bare_event = policy.on_event.to_s.split(".").last
          aggregate_name, command_name = policy.trigger_command.to_s.split(".", 2)
          label = policy.target_domain ? "triggers in #{policy.target_domain}" : "triggers"
          %(    #{event_node(bare_event)} -->|#{label}| #{command_node(aggregate_name, command_name)})
        end

        # Qualified by aggregate since two aggregates may share a command name.
        #
        # @param aggregate_name [String] the aggregate or entity that holds the command
        # @param command_name [String] the command
        # @return [String] its Mermaid node
        def command_node(aggregate_name, command_name)
          %(cmd_#{aggregate_name}_#{command_name}(["#{aggregate_name}.#{command_name}"]))
        end

        # @param event_name [String] the event
        # @return [String] its Mermaid node
        def event_node(event_name) = %(evt_#{event_name}{{"#{event_name}"}})

        # @param bluebook [Bluebook::Chapter] the assembled chapter
        # @param holder [Object] an aggregate or entity with commands or queries
        # @return [String] what the holder does, writes and answers
        def surface_diagram(bluebook, holder)
          lines = capability_edges(holder) + mutation_edges(holder) + asks_edges(holder)
          subject = "#{holder.hecks_name}'s own declared commands (and what each writes) and queries"
          Diagrams.flowchart(bluebook, subject, lines)
        end

        def capability_edges(holder)
          holder.commands.map do |command|
            "    #{holder.hecks_name}[(#{holder.hecks_name})] -->|does| #{command_node(holder.hecks_name, command.hecks_name)}"
          end
        end

        def mutation_edges(holder)
          holder.commands.flat_map do |command|
            command.mutations.map { |mutation| mutation_edge(holder, command, mutation) }
          end
        end

        def asks_edges(holder)
          holder.queries.map do |query|
            "    #{holder.hecks_name}[(#{holder.hecks_name})] -.->|asks| #{query_node(holder.hecks_name, query.hecks_name)}"
          end
        end

        def query_node(aggregate_name, query_name)
          %(qry_#{aggregate_name}_#{query_name}{"#{aggregate_name}.#{query_name}"})
        end

        def mutation_edge(holder, command, mutation)
          shape = mutation.to_h
          label = mutation_label(shape)
          target = attribute_node(holder.hecks_name, shape[:target])
          %(    #{command_node(holder.hecks_name, command.hecks_name)} -->|"#{label}"| #{target})
        end

        def mutation_label(shape)
          verb = "#{shape[:op]}s"
          # Keyed on `fields:` being present, not on a list of multi-binding ops.
          detail = shape[:fields] ? shape[:fields].keys.join(", ") : mutation_source_detail(shape[:source])
          "#{verb}: #{detail}"
        end

        # A literal can contain `"`, which breaks the label's `|"..."|` quoting; swap it for `'`.
        def mutation_source_detail(source)
          case source[:kind]
          when "literal"  then "'#{source[:value].to_s.tr('"', "'")}'"
          when "argument" then source[:name]
          else
            source[:kind]
          end
        end

        def attribute_node(holder_name, attribute_name)
          %(attr_#{holder_name}_#{attribute_name}[#{attribute_name}])
        end
      end
    end
  end
end
