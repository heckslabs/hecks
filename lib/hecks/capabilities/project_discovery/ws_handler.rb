# Hecks::Capabilities::ProjectDiscovery::WsHandler
#
# WebSocket command handler for project discovery. Intercepts
# Diagram, Explorer, Search, and Glossary commands and responds
# with the appropriate events using data from the Bridge.
#
#   WsHandler.wire(runtime, bridge)
#
module Hecks
  module Capabilities
    module ProjectDiscovery
      module WsHandler
        def self.wire(runtime, bridge)
          return unless runtime.respond_to?(:websocket)
          port = runtime.websocket
          original = port.method(:handle_message)

          port.define_singleton_method(:handle_message) do |client, raw|
            msg = JSON.parse(raw, symbolize_names: true) rescue nil
            handled = WsHandler.handle(port, client, msg, bridge)
            original.call(client, raw) unless handled
          end
        end

        def self.handle(port, client, msg, bridge)
          return false unless msg && msg[:type] == "command"
          agg = msg[:aggregate]
          cmd = msg[:command]
          args = msg[:args] || {}

          case agg
          when "Diagram"   then handle_diagram(port, client, cmd, args, bridge)
          when "Explorer"  then handle_explorer(port, client, cmd, args, bridge)
          when "Search"    then handle_search(port, client, cmd, args, bridge)
          when "Glossary"  then handle_glossary(port, client, cmd, args, bridge)
          when "Console"   then handle_console(port, client, cmd, args, bridge)
          else false
          end
        end

        def self.handle_diagram(port, client, cmd, args, bridge)
          case cmd
          when "GenerateOverview"
            overview = bridge.domain_overview
            port.send_json(client, {
              type: "event", event: "OverviewGenerated", aggregate: "Diagram",
              data: { structure: overview, behavior: nil, flow: nil }
            })
          when "GenerateDiagram"
            project = bridge.projects.keys.first
            domain_name = args[:domain] || bridge.all_domains.first&.dig(:name)
            if project && domain_name
              diagrams = bridge.diagrams_for(project, domain_name)
              port.send_json(client, {
                type: "event", event: "DiagramGenerated", aggregate: "Diagram",
                data: diagrams
              })
            end
          when "RunAnalysis"
            overview = bridge.domain_overview
            port.send_json(client, {
              type: "event", event: "AnalysisCompleted", aggregate: "Diagram",
              data: { structure: overview, behavior: nil, flow: nil }
            })
          else return false
          end
          true
        end

        def self.handle_explorer(port, client, cmd, args, bridge)
          case cmd
          when "OpenFile"
            path = args[:path]
            if path && File.exist?(path)
              content = bridge.file_content(path)
              port.send_json(client, {
                type: "event", event: "FileOpened", aggregate: "Explorer",
                data: content
              })
            end
          when "InspectAggregate"
            name = args[:aggregate_name]
            agg = find_aggregate(bridge, name)
            port.send_json(client, {
              type: "event", event: "AggregateInspected", aggregate: "Explorer",
              data: { aggregate_name: name, aggregate: agg }
            })
          when "ExportBluebook"
            domain = bridge.all_domains.first&.dig(:domain)
            if domain
              source = Hecks::DslSerializer.new(domain).serialize rescue "# Export error"
              port.send_json(client, {
                type: "event", event: "FileOpened", aggregate: "Explorer",
                data: { filename: "#{domain.name}.bluebook", content: source }
              })
            end
          else return false
          end
          true
        end

        def self.handle_search(port, client, cmd, args, bridge)
          case cmd
          when "SearchDomain"
            results = bridge.search(args[:query])
            port.send_json(client, {
              type: "event", event: "SearchCompleted", aggregate: "Search",
              data: { query: args[:query], results: results }
            })
          when "ClearSearch"
            port.send_json(client, {
              type: "event", event: "SearchCleared", aggregate: "Search",
              data: {}
            })
          else return false
          end
          true
        end

        def self.handle_glossary(port, client, cmd, args, bridge)
          case cmd
          when "ShowGlossary"
            terms = bridge.all_domains.flat_map { |d|
              domain = d[:domain]
              next [] unless domain
              domain.aggregates.map { |a|
                { name: a.name, definition: a.description || "", category: "aggregate" }
              }
            }
            port.send_json(client, {
              type: "event", event: "GlossaryShown", aggregate: "Glossary",
              data: { terms: terms }
            })
          else return false
          end
          true
        end

        def self.handle_console(port, client, cmd, args, bridge)
          case cmd
          when "SelectCommand"
            port.send_json(client, {
              type: "event", event: "CommandSelected", aggregate: "Console",
              data: { aggregate_name: args[:aggregate_name], command_name: args[:command_name] }
            })
          when "SubmitForm"
            dispatch_console_command(port, client, args, bridge)
          else return false
          end
          true
        end

        def self.dispatch_console_command(port, client, args, bridge)
          values = JSON.parse(args[:values] || "{}") rescue {}
          agg_name = values.delete("_aggregate")
          cmd_name = values.delete("_command")
          project = values.delete("_project")
          return unless agg_name && cmd_name

          rt = bridge.all_runtimes.first
          return unless rt

          sym_values = values.transform_keys(&:to_sym)
          rt.command_bus.dispatch(cmd_name, **sym_values)
        rescue => e
          port.send_json(client, { type: "error", message: "#{cmd_name}: #{e.message}" })
        end

        def self.find_aggregate(bridge, name)
          bridge.all_domains.each do |d|
            (d[:aggregates] || []).each do |a|
              return a if a[:name] == name
            end
          end
          nil
        end
      end
    end
  end
end
