require "json"
require_relative "cli_door"
require_relative "command_request"
require_relative "json_door"
require_relative "launcher_options"
require_relative "../projector"
require_relative "../ports/clock"
require_relative "cli_runner/answers"
require_relative "cli_runner/resolution"
require_relative "cli_runner/settling"
require_relative "cli_runner/streaming"
require_relative "cli_runner/suggestions"

module Hecks
  module Doors
    # Parses and dispatches a command line against a `Projector::CliProjector` projection.
    # Does no IO: it answers `[text, status]` and leaves printing and exiting to its callers.
    module CliRunner
      # The class an adapter raises when the tool it wraps refuses.
      TOOL_REFUSAL = "Hecks::Adapters::ConsoleCapture::Failure".freeze
      # The words that open the query namespace; `ask` is the older spelling.
      QUERY_WORDS = %w[query ask].freeze

      extend Resolution
      extend Suggestions
      extend Answers
      extend Settling
      extend Streaming

      module_function

      # Runs one command line against a booted domain and answers the text to print.
      # The booted domain's own chapter is projected, or an attached one its first word names.
      #
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted domain
      # @param argv [Array<String>] an optional `query` (or `ask`), the command or query name, then
      #   `path=value` pairs; `--help`, `-h`, `help` or nothing answers usage
      # @param program [String] how the caller was invoked, echoed in usage and hints
      # @return [Array(String, Integer)] the text and the status: 0 answered, 1 refused or misused
      # @raise [Runtime::WiringError] if a repository or the clock adapter cannot be resolved
      # @raise [Runtime::StaleWrite] if concurrent writers beat the command through every retry
      def call(runtime:, argv:, program: "hecks run")
        plan = resolve(runtime, argv, program)
        return plan[:answer] if plan[:answer]

        dispatch(runtime, plan[:spec], plan[:name], plan[:rest], plan[:program], plan[:asking],
                 bluebook: plan[:bluebook], launcher: plan[:launcher])
      end

      # Answers a command line that asks only for usage, from the projection alone.
      #
      # Needs a registry and no bound adapter, so a `Runtime::Loader::Described` serves: the
      # help text, the no-argument usage, a command's `--help` and an unknown one's hint all come
      # out byte-identical to `call`'s.
      #
      # @param runtime [#registry] a booted domain, or what `Hecks.describe` answers
      # @param argv [Array<String>] as for `call`
      # @param program [String] how the caller was invoked
      # @return [Array(String, Integer), nil] the text and status, or nil when the line would
      #   run a command or question and so needs a booted domain
      def usage(runtime:, argv:, program: "hecks run")
        UsageCache.fetch(runtime, argv, program, audience: audience_key) { resolve(runtime, argv, program)[:answer] }
      end
    end
  end
end
