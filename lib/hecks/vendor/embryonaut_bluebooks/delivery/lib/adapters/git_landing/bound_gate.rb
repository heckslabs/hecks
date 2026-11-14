# frozen_string_literal: true

require "hecks/runtime/adapter_lookup"
require "hecks/hecks/adapters/console_capture"

module Hecks
  module Adapters
    class GitLanding
      # The gate a landing asks before it merges: the adapter the project bound to the `Gate` port.
      #
      # What a gate holds differs from one repository to the next, and a bluebook says so the way
      # it says anything about the outside: a port, and the adapter a hecksagon binds to it. Each
      # project binds its own. A project that binds none has no gate, and its landing is refused by
      # the lookup, never passed (Hecks ADR 0205).
      class BoundGate
        # The port a project binds its gate to.
        PORT = "Gate"

        # What the gate is asked, worded into the refusal of a project that binds none.
        ASKED = "whether a worktree may land"

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

        # A landing made with no booted registry has no project, and so no gate to ask.
        def adapter
          return Runtime::AdapterLookup.call(@registry, PORT, asked: ASKED) if @registry.respond_to?(:adapters)

          raise ConsoleCapture::Failure, "no gate: this landing was made with no booted project to bind one"
        end
      end
    end
  end
end
