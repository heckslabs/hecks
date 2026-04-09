# Hecks::Capabilities::ProductExecutor
#
# @domain ProductExecutor
#
# Eight-agent product team capability. Each agent is a named persona with
# its own system prompt, tools, and conversation history. All share access
# to the domain IR and can validate against the UL.
#
# Agents: Jesper (product owner), Chris (scrum master), Alberto (event storming),
# Eric (planner), Alistair (domain builder), Uncle Bob (app builder),
# Don (UX), Jony (UI).
#
#   # Hecksagon planning concern:
#   concern :planning do
#     eric.prompt.ai_responder adapter: :claude, emits: "PlanProposed"
#   end
#
require_relative "dsl"

module Hecks
  module Capabilities
    module ProductExecutor
      AGENTS = %w[jesper chris alberto eric alistair uncle_bob don jony].freeze

      AGENT_MODULES = {
        "jesper"    => -> { Jesper },
        "chris"     => -> { Chris },
        "alberto"   => -> { Alberto },
        "eric"      => -> { Eric },
        "alistair"  => -> { Alistair },
        "uncle_bob" => -> { UncleBob },
        "don"       => -> { Don },
        "jony"      => -> { Jony }
      }.freeze

      # Build the shared tool set available to all agents.
      #
      # @param domain [Hecks::BluebookModel::Structure::Domain]
      # @return [Array<Hash>] tool definitions
      def self.shared_tools(domain)
        [
          { name: "ListAggregates", description: "List all aggregates in the domain",
            parameters: [] },
          { name: "DescribeAggregate", description: "Show full details of an aggregate",
            parameters: [{ name: "aggregate_name", type: "string", required: true }] },
          { name: "ValidateUL", description: "Validate domain tags against the ubiquitous language",
            parameters: [] },
          { name: "DelegateToAgent", description: "Ask another agent to do something",
            parameters: [
              { name: "agent_name", type: "string", required: true },
              { name: "task", type: "string", required: true }
            ] }
        ]
      end

      # Apply the product executor capability to a runtime.
      #
      # @param runtime [Hecks::Runtime] the booted runtime
      # @return [void]
      def self.apply(runtime)
        domain = runtime.domain
        adapter = nil # resolved lazily on first message

        agents = {}
        AGENT_MODULES.each do |name, mod_proc|
          agents[name] = mod_proc.call.config(domain)
        end

        add_smes(agents, runtime)

        runner = AgentRunner.new(adapter: adapter, runtime: runtime, agents: agents)
        runtime.instance_variable_set(:@product_executor, runner)
        runtime.define_singleton_method(:product_executor) { @product_executor }

        wire_websocket(runtime, runner)
        puts "  \e[32m✓\e[0m product_executor (#{AGENTS.size} agents)"
      end

      # Wire WebSocket message handling for executor commands.
      #
      # @param runtime [Hecks::Runtime]
      # @param runner [AgentRunner]
      def self.wire_websocket(runtime, runner)
        return unless runtime.respond_to?(:websocket)
        port = runtime.websocket
        original = port.method(:handle_message)

        port.define_singleton_method(:handle_message) do |client, raw|
          msg = JSON.parse(raw, symbolize_names: true) rescue nil

          # Handle domain command: ProductExecutor.SendToAgent
          if msg && msg[:type] == "command" && msg[:aggregate] == "ProductExecutor"
            args = msg[:args] || {}
            port.broadcast_event({
              event: "AgentMessageSent", aggregate: "ProductExecutor",
              data: { agent_name: args[:agent_name], content: args[:content] }
            })
          elsif msg && msg[:type] == "executor"
            content = msg[:content]&.to_s

            if content.strip.upcase == "QUIET!"
              runner.quiet!
              runner.agent_names.each do |name|
                port.send_json(client, { type: "executor_thinking", agent: name, thinking: false })
              end
              port.send_json(client, {
                type: "executor_message", agent: "chris",
                role: "assistant", content: "Everyone's quiet."
              })
            else
              target, clean_content = runner.parse_mention(content)

              if target
                port.send_json(client, { type: "executor_thinking", agent: target, thinking: true })
                runner.send_to(target, clean_content) do |agent_name, response|
                  port.send_json(client, { type: "executor_thinking", agent: agent_name, thinking: false })
                  port.send_json(client, {
                    type: "executor_message", agent: agent_name,
                    role: "assistant", content: response[:content] || response.to_s
                  })
                end
              else
                runner.route(content) do |agent_name, response|
                  port.send_json(client, { type: "executor_thinking", agent: agent_name, thinking: false })
                  port.send_json(client, {
                    type: "executor_message", agent: agent_name,
                    role: "assistant", content: response[:content] || response.to_s
                  })
                end
              end
            end
          else
            original.call(client, raw)
          end
        end
      end

      # Add SMEs from project domains as dynamic agents in the room.
      #
      # @param agents [Hash] existing agent configs
      # @param runtime [Hecks::Runtime]
      def self.add_smes(agents, runtime)
        bridge = runtime.respond_to?(:projects) ? runtime.projects : nil
        return unless bridge

        bridge.projects.each do |_path, project|
          (project[:runtimes] || []).each do |rt|
            sme = rt.domain.sme
            next unless sme

            slug = sme[:name].downcase.gsub(/[^a-z0-9]/, "_").gsub(/_+/, "_")
            agents[slug] = {
              role: "sme",
              system_prompt: build_sme_prompt(sme, rt.domain),
              tools: shared_tools(rt.domain)
            }
          end
        end
      end

      def self.build_sme_prompt(sme, domain)
        <<~PROMPT
          You are #{sme[:name]}, a subject matter expert for the #{domain.name} domain.

          #{sme[:expertise]}

          You know this domain deeply from real-world experience. When the team discusses features in #{domain.name}, you provide ground truth — what actually happens in practice, what edge cases exist, what the team is missing. You correct misconceptions. You share war stories. You are opinionated because you've lived it.

          Domain context: #{domain.vision || domain.description || domain.name}
          Aggregates: #{domain.aggregates.map(&:name).join(", ")}
        PROMPT
      end

      private_class_method :wire_websocket, :add_smes, :build_sme_prompt

      Dir[File.expand_path("product_executor/*.rb", __dir__)].sort.each { |f| require f }
    end
  end
end

Hecks.capability :product_executor do
  description "Eight-agent product team: plan, build domain, build app, UX, UI, product owner, scrum master, event storming"
  direction :driven
  on_apply do |runtime|
    Hecks::Capabilities::ProductExecutor.apply(runtime)
  end
end
