# Hecks::Capabilities::ChatAgent
#
# Capability that wires a chat agent into the domain. Reads ai_responder
# annotations from the Hecksagon, auto-generates tool definitions and a
# system prompt from the domain IR, and dispatches through the command bus.
#
# Default adapter is memory (canned responses). Configure a real adapter
# (e.g. :claude) via the World file.
#
#   # Hecksagon:
#   Chat.prompt.ai_responder adapter: :claude, emits: "Replied"
#
#   # At runtime:
#   runtime.capability(:chat_agent)
#
require_relative "dsl"

module Hecks
  module Capabilities
    module ChatAgent
      @adapters = {}

      # Register a named adapter instance.
      #
      # @param name [Symbol] adapter name (e.g. :claude, :openai)
      # @param instance [#chat] adapter that responds to chat(messages:, tools:, system:)
      def self.register_adapter(name, instance)
        @adapters[name.to_sym] = instance
      end

      # Retrieve a registered adapter, falling back to memory.
      #
      # When name is nil, auto-picks the sole registered adapter so the
      # Hecksagon doesn't need to name it when only one is configured.
      #
      # @param name [Symbol, nil] adapter name (nil = auto-resolve)
      # @param config [Hash] config from World file (used for memory adapter)
      # @return [#chat] adapter instance
      def self.resolve_adapter(name, config)
        if name
          @adapters[name.to_sym] || MemoryAdapter.new(**config)
        elsif @adapters.size == 1
          @adapters.values.first
        else
          MemoryAdapter.new(**config)
        end
      end

      # Apply the chat agent capability to a runtime.
      #
      # Reads ai_responder annotations from the Hecksagon, builds tools and
      # system prompt from the domain IR, resolves the adapter, and stores
      # the wiring on the runtime for use by the Chat aggregate.
      #
      # @param runtime [Hecks::Runtime] the booted runtime
      # @return [void]
      def self.apply(runtime)
        hecksagon = Hecks.last_hecksagon
        world = Hecks.last_world
        annotations = (hecksagon&.annotations || []).select { |a| a[:annotation] == :ai_responder }
        return if annotations.empty?

        domain = runtime.domain
        tools = ToolBuilder.build(domain)
        system_prompt = SystemPromptBuilder.build(domain)

        annotations.each do |ann|
          adapter_name = ann[:adapter]

          runtime.instance_variable_set(:@chat_agent, {
            adapter_name: adapter_name,
            tools: tools,
            system_prompt: system_prompt,
            emits: ann[:emits],
            aggregate: ann[:aggregate],
            attribute: ann[:attribute]
          })
        end

        puts "chat_agent capability applied"
      end

      # Load extracted modules from the chat_agent/ subdirectory.
      Dir[File.expand_path("chat_agent/*.rb", __dir__)].sort.each { |f| require f }
    end
  end
end

Hecks.capability :chat_agent do
  description "AI chat agent wired to domain commands via ai_responder annotations"
  direction :driven
  on_apply do |runtime|
    Hecks::Capabilities::ChatAgent.apply(runtime)
  end
end
