require_relative "../runtime/registry"

module Hecks
  module Composer
    # The agent the Composer asks, on the hecksagon side: one port, `composer_agent`, resolved to
    # the single adapter a registry holds for it. The caller never sees the adapter, only answers
    # this module has checked, so a spec can stand a scripted adapter in for the real one.
    #
    # Two of the asks change the workspace on disk and answer with a note about what changed:
    # `draft` edits a bluebook, `wire` edits the `.hecksagon` and `.world` files that bind it. The
    # third, `classify`, only names what a prompt is asking for.
    module Agent
      NAME = "composer_agent".freeze
      PORT = File.expand_path("ports/composer_agent.port", __dir__).freeze
      ADAPTERS = File.expand_path("adapters", __dir__).freeze

      # What a prompt can be asking for.
      INTENTS = %w[edit wire question new_domain].freeze

      # The adapter's answer arrived but was unusable; asking again will not help.
      class ValidationError < StandardError
      end

      # Nothing answered (missing binary, dead subprocess, timeout); retry or fall back.
      class Unavailable < StandardError
      end

      module_function

      # Asks the agent to change a workspace's bluebooks as the prompt says.
      #
      # @param registry [Runtime::Registry] a registry holding the port and one adapter for it
      # @param prompt [String] what the author asked for
      # @param dir [String] the workspace directory, whose files the agent edits in place
      # @return [String] the agent's one-line account of what it changed
      # @raise [ValidationError] unless the answer is a Hash with a non-blank `"note"`
      # @raise [Unavailable] if the adapter cannot answer
      # @raise [Runtime::WiringError] unless exactly one adapter implements the port
      def draft(registry, prompt:, dir:)
        note(adapter(registry).draft(prompt: prompt, dir: dir))
      end

      # Asks the agent to change how a workspace's bluebook is wired, never what it declares.
      #
      # @param registry [Runtime::Registry] a registry holding the port and one adapter for it
      # @param prompt [String] what the author asked for
      # @param dir [String] the workspace directory, whose `.hecksagon` and `.world` files the
      #   agent edits in place
      # @return [String] the agent's one-line account of what it changed
      # @raise [ValidationError] unless the answer is a Hash with a non-blank `"note"`
      # @raise [Unavailable] if the adapter cannot answer
      def wire(registry, prompt:, dir:)
        note(adapter(registry).wire(prompt: prompt, dir: dir))
      end

      # Names what a prompt is asking for.
      #
      # @param registry [Runtime::Registry] a registry holding the port and one adapter for it
      # @param prompt [String] what the author typed
      # @return [String] one of `Composer::Agent::INTENTS`
      # @raise [ValidationError] unless the answer is a Hash whose `"intent"` is one of those
      # @raise [Unavailable] if the adapter cannot answer
      def classify(registry, prompt:)
        answer = adapter(registry).classify(prompt: prompt)
        intent = answer["intent"] if answer.is_a?(Hash)
        return intent if INTENTS.include?(intent)

        raise ValidationError, "an intent is one of #{INTENTS.join(", ")}, got #{intent.inspect}"
      end

      # Builds a registry in which exactly one adapter implements the port.
      #
      # @param adapter_file [String] the adapter's `.adapter` declaration
      # @return [Runtime::Registry] a registry holding the port and that adapter
      def registry_with(adapter_file)
        registry = Runtime::Registry.new
        Hecks.with_registry(registry) do
          Kernel.load(PORT)
          Kernel.load(adapter_file)
        end
        registry
      end

      # Finds the single adapter bound to the port.
      #
      # @param registry [Runtime::Registry] the registry to search
      # @return [Module] the adapter implementing the port
      # @raise [Runtime::WiringError] if none, or more than one, implements the port
      def adapter(registry)
        implementations = registry.adapters.values.select { |found| found.port == NAME }
        return registry.adapter_class(implementations.first.name) if implementations.size == 1

        raise Runtime::WiringError, wiring_refusal(implementations)
      end

      # @api private
      def note(answer)
        text = answer["note"].to_s.strip if answer.is_a?(Hash)
        return text unless text.nil? || text.empty?

        raise ValidationError, "an agent's answer carries a non-blank \"note\", got #{answer.inspect}"
      end

      # @api private
      def wiring_refusal(implementations)
        return "no adapter implements the #{NAME} port — nothing can edit the draft" if implementations.empty?

        names = implementations.map(&:name).sort.join(", ")
        "#{implementations.size} adapters implement the #{NAME} port (#{names}) — the runtime will not choose for you"
      end
    end
  end
end
