# Hecks::Capabilities::ProductExecutor::AgentRunner
#
# @domain ProductExecutor.SendToAgent
#
# Group chat runner. Every message goes to ALL agents in parallel.
# Each agent sees the full conversation and decides whether to respond.
# "QUIET!" cancels all pending agent threads.
#
#   runner = AgentRunner.new(adapter:, runtime:, agents:)
#   runner.broadcast("Plan a notification system") { |agent, response| ... }
#
module Hecks
  module Capabilities
    module ProductExecutor
      class AgentRunner
        # @param adapter [#chat] the LLM adapter
        # @param runtime [Hecks::Runtime] for tool call dispatch
        # @param agents [Hash<String, Hash>] agent configs keyed by name
        def initialize(adapter:, runtime:, agents:)
          @adapter = adapter
          @runtime = runtime
          @agents = agents
          @bullpen_config = Bullpen.config(nil, agents.keys)
          @conversation = []
          @active_threads = []
          @mutex = Mutex.new
        end

        # Ask the bullpen agent who should respond, then send only to them.
        def route(content, &on_response)
          @mutex.synchronize { @conversation << { role: "user", content: content } }

          # Ask the invisible moderator
          adapter = resolve_adapter("bullpen")
          messages = [{ role: "user", content: content }]
          result = ChatAgent::Dispatcher.run_loop(
            adapter: adapter, messages: messages, tools: [],
            system: @bullpen_config[:system_prompt], runtime: @runtime
          )

          # Parse comma-separated agent names
          picked = (result[:content] || "chris").split(",").map(&:strip).map(&:downcase)
          picked = picked.select { |n| @agents.key?(n) }
          picked = ["chris"] if picked.empty?

          picked.each do |name|
            config = @agents[name]
            next unless config
            thread = Thread.new do
              begin
                msgs = build_messages(name, config)
                response = ChatAgent::Dispatcher.run_loop(
                  adapter: resolve_adapter(name), messages: msgs, tools: config[:tools],
                  system: config[:system_prompt], runtime: @runtime
                )
                if response[:content] && !response[:content].empty?
                  @mutex.synchronize do
                    @conversation << { role: "assistant", agent: name, content: response[:content] }
                  end
                  on_response.call(name, response) if on_response
                end
              rescue => e
                on_response.call(name, { content: "Error: #{e.message}" }) if on_response
              end
            end
            @mutex.synchronize { @active_threads << thread }
          end
        end

        # Broadcast a message to all agents. Each responds in its own thread.
        # The block is called for each agent that responds.
        #
        # @param content [String] the user message
        # @yield [agent_name, response] called per agent response
        # Send to a specific agent by name. Only that agent responds.
        def send_to(agent_name, content, &on_response)
          config = @agents[agent_name]
          return unless config
          @mutex.synchronize { @conversation << { role: "user", content: content } }

          thread = Thread.new do
            begin
              messages = build_messages(agent_name, config)
              response = ChatAgent::Dispatcher.run_loop(
                adapter: resolve_adapter(agent_name), messages: messages, tools: config[:tools],
                system: config[:system_prompt], runtime: @runtime
              )
              if response[:content] && !response[:content].empty?
                @mutex.synchronize do
                  @conversation << { role: "assistant", agent: agent_name, content: response[:content] }
                end
                on_response.call(agent_name, response) if on_response
              end
            rescue => e
              on_response.call(agent_name, { content: "Error: #{e.message}" }) if on_response
            end
          end
          @mutex.synchronize { @active_threads << thread }
        end

        # Parse @mentions from content. Returns [target_name, clean_content] or [nil, content].
        def parse_mention(content)
          if content =~ /\A@(\w+)\s*(.*)/m
            name = $1.downcase
            name = "uncle_bob" if name == "unclebob"
            [@agents.key?(name) ? name : nil, $2.strip]
          else
            [nil, content]
          end
        end

        def broadcast(content, &on_response)
          @mutex.synchronize { @conversation << { role: "user", content: content } }

          @agents.each do |name, config|
            thread = Thread.new do
              begin
                messages = build_messages(name, config)
                response = ChatAgent::Dispatcher.run_loop(
                  adapter: resolve_adapter(name), messages: messages, tools: config[:tools],
                  system: config[:system_prompt], runtime: @runtime
                )
                if response[:content] && !response[:content].empty?
                  @mutex.synchronize do
                    @conversation << { role: "assistant", agent: name, content: response[:content] }
                  end
                  on_response.call(name, response) if on_response
                end
              rescue => e
                on_response.call(name, { content: "Error: #{e.message}" }) if on_response
              end
            end
            @mutex.synchronize { @active_threads << thread }
          end
        end

        # Stop all pending agent threads.
        def quiet!
          @mutex.synchronize do
            @active_threads.each { |t| t.kill if t.alive? }
            @active_threads.clear
          end
        end

        # Clear all conversation history.
        def clear_all
          @mutex.synchronize { @conversation.clear }
        end

        # @return [Array<String>]
        def agent_names
          @agents.keys
        end

        private

        def resolve_adapter(agent_name = nil)
          @adapters ||= {}
          @adapters[agent_name] ||= begin
            base = Hecks::Capabilities::ChatAgent.resolve_adapter(nil, {})
            if agent_name == "uncle_bob" && base.is_a?(Hecks::Extensions::ClaudeCliAdapter)
              Hecks::Extensions::ClaudeCliAdapter.new(
                model: base.instance_variable_get(:@model),
                dangerously_skip_permissions: true
              )
            else
              base
            end
          end
        end

        def build_messages(agent_name, _config)
          @mutex.synchronize do
            @conversation.map do |msg|
              if msg[:agent] && msg[:agent] != agent_name
                { role: "user", content: "[#{msg[:agent]}]: #{msg[:content]}" }
              else
                { role: msg[:role], content: msg[:content] }
              end
            end
          end
        end
      end
    end
  end
end
