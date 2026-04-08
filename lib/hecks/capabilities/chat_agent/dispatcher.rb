# Hecks::Capabilities::ChatAgent::Dispatcher
#
# Routes tool calls from an LLM response back through the domain's command
# bus. Each tool call is resolved to a command, executed, and the result
# serialized back for the next LLM turn.
#
#   results = Dispatcher.dispatch_tool_calls(runtime, tool_calls)
#   # => [{ tool_call_id: "tc_1", result: "name: Margherita, size: Large" }]
#
module Hecks
  module Capabilities
    module ChatAgent
      module Dispatcher
        MAX_ITERATIONS = 10

        # Dispatch an array of tool calls through the runtime.
        #
        # @param runtime [Hecks::Runtime] the booted runtime
        # @param tool_calls [Array<Hash>] tool calls from the LLM
        #   Each: { id: String, name: String, arguments: Hash }
        # @return [Array<Hash>] results for each tool call
        def self.dispatch_tool_calls(runtime, tool_calls)
          tool_calls.map do |tc|
            dispatch_one(runtime, tc)
          end
        end

        # Run the full conversation loop: send to adapter, dispatch tool calls,
        # repeat until the model responds with text (no tool calls) or we hit
        # the max iteration limit.
        #
        # @param adapter [#chat] the LLM adapter
        # @param messages [Array<Hash>] conversation history
        # @param tools [Array<Hash>] tool definitions
        # @param system [String] system prompt
        # @param runtime [Hecks::Runtime] for dispatching tool calls
        # @return [Hash] final assistant response { role:, content: }
        def self.run_loop(adapter:, messages:, tools:, system:, runtime:)
          iterations = 0
          loop do
            iterations += 1
            response = adapter.chat(messages: messages, tools: tools, system: system)

            if response[:tool_calls].nil? || response[:tool_calls].empty?
              return response
            end

            if iterations >= MAX_ITERATIONS
              return { role: "assistant", content: "Reached maximum tool call iterations." }
            end

            messages << { role: "assistant", tool_calls: response[:tool_calls] }
            results = dispatch_tool_calls(runtime, response[:tool_calls])
            results.each do |r|
              messages << { role: "tool", tool_call_id: r[:tool_call_id], content: r[:result] || r[:error] }
            end
          end
        end

        def self.dispatch_one(runtime, tc)
          name = tc[:name] || tc["name"]
          args = (tc[:arguments] || tc["arguments"] || {}).transform_keys(&:to_sym)
          begin
            result = runtime.run(name, **args)
            { tool_call_id: tc[:id] || tc["id"], result: serialize(result) }
          rescue => e
            { tool_call_id: tc[:id] || tc["id"], error: e.message }
          end
        end

        def self.serialize(result)
          return result.to_s unless result.respond_to?(:class)
          if result.respond_to?(:attributes)
            result.attributes.map { |k, v| "#{k}: #{v}" }.join(", ")
          else
            result.to_s
          end
        end

        private_class_method :dispatch_one, :serialize
      end
    end
  end
end
