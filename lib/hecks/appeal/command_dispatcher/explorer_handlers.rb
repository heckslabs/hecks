# Hecks::Appeal::CommandDispatcher::ExplorerHandlers
#
# Handles explorer, console, agent, event stream, and diagram commands.
# Mixed into CommandDispatcher for domain exploration and interaction.
#
#   # Automatically included by CommandDispatcher
#   include Hecks::Appeal::CommandDispatcher::ExplorerHandlers
#
module Hecks
  module Appeal
    class CommandDispatcher
      module ExplorerHandlers
        private

        # -- Explorer --
        def handle_explorer_load_domain(ws, args)
          project = @bridge.projects[args[:path]]
          domain = project&.dig(:domains)&.find { |d| d[:name] == args[:domain] }
          emit(ws, "DomainLoaded", "Explorer", { domain: domain })
        end

        def handle_explorer_inspect_aggregate(ws, args)
          project = @bridge.projects[args[:path]]
          domain = project&.dig(:domains)&.find { |d| d[:name] == args[:domain] }
          agg = domain&.dig(:aggregates)&.find { |a| a[:name] == args[:aggregate] }
          emit(ws, "AggregateInspected", "Explorer", { aggregate: agg })
        end

        def handle_explorer_open_file(ws, args)
          data = @bridge.file_content(args[:path])
          project = find_project_for_file(args[:path])
          event_data = data.merge(path: args[:path])
          event_data[:project_path] = project[:path] if project
          event_data[:domain] = project[:domains]&.first&.dig(:name) if project
          emit(ws, "FileOpened", "Explorer", event_data)
        end

        # -- Console --
        def handle_console_select_command(ws, args) = emit(ws, "CommandSelected", "Console", args)

        def handle_console_submit_form(ws, args)
          broadcast_event("CommandExecuted", args[:aggregate] || "Unknown", {
            command: args[:command], timestamp: Time.now.strftime("%H:%M:%S"), args: args[:fields] || {}
          })
        end

        # -- Agent --
        def handle_agent_send_message(ws, args)
          content = (args[:content] || "").strip
          emit(ws, "AgentMessageReceived", "Agent", { role: "user", content: content })
          emit(ws, "AgentThinking", "Agent", { thinking: true })

          adapter = agent_adapter(ws)
          prompt = agent_system_prompt
          tools = agent_tools
          runtime = @bridge.all_runtimes.first

          history = agent_history(ws)
          history << { role: "user", content: content }

          reply = begin
            require_chat_agent
            response = Hecks::Capabilities::ChatAgent::Dispatcher.run_loop(
              adapter: adapter, messages: history, tools: tools,
              system: prompt, runtime: runtime
            )
            history << { role: "assistant", content: response[:content] }
            response[:content]
          rescue => e
            $stderr.puts "[Agent] Error: #{e.class}: #{e.message}"
            $stderr.flush
            "Error: #{e.message}"
          end

          emit(ws, "AgentThinking", "Agent", { thinking: false })
          emit(ws, "AgentMessageReceived", "Agent", { role: "assistant", content: reply })
        end

        def handle_agent_clear_conversation(ws, _)
          @agent_histories&.delete(ws.object_id)
          emit(ws, "ConversationCleared", "Agent", {})
        end

        def handle_agent_toggle_adapter(ws, args)
          mode = (args[:mode] || "memory").to_s
          layout(ws).agent_mode = mode
          emit(ws, "AgentAdapterChanged", "Agent", { mode: mode })
        end

        def agent_history(ws)
          @agent_histories ||= {}
          @agent_histories[ws.object_id] ||= []
        end

        def agent_adapter(ws)
          require_chat_agent
          mode = layout(ws).respond_to?(:agent_mode) ? layout(ws).agent_mode : "memory"
          if mode == "live"
            @live_adapter ||= build_live_adapter
          else
            @memory_adapter ||= Hecks::Capabilities::ChatAgent::MemoryAdapter.new
          end
        end

        def build_live_adapter
          require "hecks/extensions/claude"
          world = load_appeal_world
          config = world&.config_for(:claude) || {}
          model = config[:model] || "sonnet"
          max_tokens = config[:max_tokens] || 4096

          if config[:api_key] && !config[:api_key].to_s.empty?
            Hecks::Extensions::ClaudeAdapter.new(
              api_key: config[:api_key], model: model, max_tokens: max_tokens
            )
          else
            Hecks::Extensions::ClaudeCliAdapter.new(
              model: model, max_tokens: max_tokens
            )
          end
        end

        def load_appeal_world
          world_file = File.expand_path("../../chapters/appeal/world.hec", __dir__)
          return nil unless File.exist?(world_file)
          Hecks.last_world = nil
          Kernel.load(world_file)
          Hecks.last_world
        end

        def agent_system_prompt
          @agent_system_prompt = nil if bridge_domains_changed?
          @agent_system_prompt ||= bridge_domain_irs.map { |d|
            Hecks::Capabilities::ChatAgent::SystemPromptBuilder.build(d)
          }.join("\n\n")
        end

        def agent_tools
          @agent_tools = nil if bridge_domains_changed?
          @agent_tools ||= bridge_domain_irs.flat_map { |d|
            Hecks::Capabilities::ChatAgent::ToolBuilder.build(d)
          }
        end

        def bridge_domain_irs
          @bridge.all_domains.filter_map { |d| d[:domain] }
        end

        def bridge_domains_changed?
          current = @bridge.all_domains.map { |d| d[:name] }
          changed = current != @last_domain_names
          @last_domain_names = current
          changed
        end

        def require_chat_agent
          return if defined?(Hecks::Capabilities::ChatAgent)
          require "hecks/capabilities/chat_agent"
        end

        # -- EventStream --
        def handle_event_stream_pause_stream(ws, _)
          layout(ws).pause_stream
          emit(ws, "StreamPaused", "EventStream", {})
        end

        def handle_event_stream_resume_stream(ws, _)
          layout(ws).resume_stream
          emit(ws, "StreamResumed", "EventStream", {})
        end

        def handle_event_stream_clear_events(ws, _) = emit(ws, "EventsCleared", "EventStream", {})

        def handle_event_stream_filter_events(ws, args)
          layout(ws).filter_events(args[:filter])
          emit(ws, "EventsFiltered", "EventStream", { filter: args[:filter] })
        end

        # -- Diagram --
        def handle_diagram_generate_diagram(ws, args)
          emit(ws, "DiagramsGenerated", "Diagram", @bridge.diagrams_for(args[:path], args[:domain]))
        end

        def handle_diagram_generate_overview(ws, _)
          emit(ws, "BluebookOverviewGenerated", "Diagram", { structure: @bridge.domain_overview })
        end

        def handle_diagram_select_view(ws, args)
          layout(ws).select_diagram_view(args[:view])
          emit(ws, "ViewSelected", "Diagram", { view: args[:view] })
        end
      end
    end
  end
end
