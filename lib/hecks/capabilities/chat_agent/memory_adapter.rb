# Hecks::Capabilities::ChatAgent::MemoryAdapter
#
# Default in-memory adapter for the chat agent capability. Returns canned
# responses without making any API calls. Used in workshop play mode,
# tests, and any environment where no LLM adapter is configured.
#
#   adapter = MemoryAdapter.new
#   adapter.chat(messages: [...], tools: [...], system: "...")
#   # => { role: "assistant", content: "I'm a test response...", tool_calls: [] }
#
module Hecks
  module Capabilities
    module ChatAgent
      class MemoryAdapter
        CANNED_RESPONSE = "I'm a test response from the memory adapter. " \
          "Configure an LLM adapter in your World file for real responses."

        def initialize(**_config)
        end

        # Return a canned response with no tool calls.
        #
        # @param messages [Array<Hash>] conversation messages (ignored)
        # @param tools [Array<Hash>] available tools (ignored)
        # @param system [String] system prompt (ignored)
        # @return [Hash] normalized response with :role, :content, :tool_calls
        def chat(messages:, tools:, system:)
          { role: "assistant", content: CANNED_RESPONSE, tool_calls: [] }
        end
      end
    end
  end
end
