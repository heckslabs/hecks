# frozen_string_literal: true

require "hecks/runtime/adapter_lookup"
require_relative "../checkout_gate"
require_relative "../console_capture"

module Hecks
  module Adapters
    class GitLanding
      # The gate a landing asks before it merges: the adapter the project bound to the `Gate` port.
      #
      # What a gate holds differs from one repository to the next, and a bluebook says so the way
      # it says anything about the outside: a port, and the adapter a hecksagon binds to it. Hecks
      # binds `CheckoutGate`, which asks its own launcher; another project binds its own. A project
      # that binds none has no gate, and its landing is refused by the lookup, never passed
      # (ADR 0205).
      class BoundGate
        # The port a project binds its gate to.
        PORT = "Gate"

        # @param registry [Runtime::Registry, nil] the booted registry whose adapters are searched
        def initialize(registry)
          @registry = registry
        end

        # Asks the gate to judge a worktree.
        #
        # @param directory [String] the worktree
        # @return [String, nil] why it may not land, or nil when its gate is green
        # @raise [Runtime::WiringError] when the project binds no adapter, or several, to the port
        def refusal(directory)
          adapter.judge(checkout: { value: directory })
          nil
        rescue ConsoleCapture::Failure => e
          e.message
        end

        private

        # A landing made with no booted registry, as a spec makes one, is judged by `CheckoutGate`.
        def adapter
          return CheckoutGate.new unless @registry.respond_to?(:adapters)

          Runtime::AdapterLookup.call(@registry, PORT, asked: "whether a worktree may land")
        end
      end
    end
  end
end
