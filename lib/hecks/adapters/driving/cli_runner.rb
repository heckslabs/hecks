require "json"
require_relative "cli"
require_relative "command_request"
require_relative "context_line"
require_relative "exit_status"
require_relative "write_guard"
require_relative "json"
require_relative "launcher_options"
require_relative "newcomer"
require_relative "../../projector"
require_relative "../../ports/clock"
require_relative "cli_runner/answers"
require_relative "cli_runner/resolution"
require_relative "cli_runner/search_words"
require_relative "cli_runner/settling"
require_relative "cli_runner/streaming"
require_relative "cli_runner/suggestions"
require_relative "cli_runner/verb_names"

module Hecks
  module Adapters
    module Driving
      # Parses and dispatches a command line against a `Projector::CliProjector` projection.
      # Does no IO: it answers `[text, status]` (an `ExitStatus`) and leaves printing and exiting
      # to its callers.
      module CliRunner
        include ExitStatus

        # The class an adapter raises when the tool it wraps refuses.
        TOOL_REFUSAL = "Hecks::Adapters::ConsoleCapture::Failure".freeze
        # The words that open the query namespace; `ask` is the older spelling.
        QUERY_WORDS = %w[query ask].freeze

        extend Resolution
        extend SearchWords
        extend Suggestions
        extend VerbNames
        extend Answers
        extend Settling
        extend Streaming

        module_function

        # Runs one command line against a booted domain and answers the text to print.
        # The booted domain's own bluebook is projected, or an attached one its first word names.
        #
        # @param runtime [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] the booted domain
        # @param argv [Array<String>] an optional `query` (or `ask`), the command or query name,
        #   then `path=value` pairs; `--help`, `-h`, `help` or nothing answers usage
        # @param program [String] how the caller was invoked, echoed in usage and hints
        # @return [Array(String, Integer)] the text and the `ExitStatus`: `ANSWERED`, `REFUSED`
        #   when the domain said no or the run failed, `USAGE` when the line could not be read
        # @raise [Runtime::WiringError] if a repository or the clock adapter cannot be resolved
        # @raise [Runtime::StaleWrite] if concurrent writers beat the command through every retry
        def call(runtime:, argv:, program: "hecks run", usage_log: false, err: $stderr)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          plan = resolve(runtime, argv, program)
          return plan[:answer] if plan[:answer]

          refused = guard_command(plan, err)
          return [refused, ExitStatus::REFUSED] if refused

          answer = dispatch(runtime, plan[:spec], plan[:name], plan[:rest], plan[:program], plan[:asking],
                            bluebook: plan[:bluebook], launcher: plan[:launcher])
          UsageLog.record(argv: argv, resolved: plan[:name], status: answer[1], started: started) if usage_log
          answer
        end

        # Before a command (not a query) runs: refuses a write that would land in Memory from a
        # worktree whose main checkout stores it elsewhere, else prints the context line.
        #
        # @api private
        # @return [String, nil] the refusal, or nil when the command may run
        def guard_command(plan, err)
          return if plan[:asking]

          refusal = WriteGuard.refusal(Dir.pwd, plan[:bluebook]&.name)
          return refusal if refusal

          ContextLine.announce(err)
          nil
        end

        # The names a person can type at the launcher, as the projection names them: commands and
        # queries, leaving out the internal steps a run records about itself.
        #
        # @param runtime [#registry] a booted domain, or what `Hecks.describe` answers
        # @param program [String] how the caller was invoked
        # @return [Array<String>] the sorted names
        def known_names(runtime:, program: "hecks run")
          bluebook, = bluebook_for(runtime, [], program)
          launcher = LauncherOptions.settings(runtime, bluebook.name)
          options = LauncherOptions.projection(launcher, program)
          cli = Projector.call(:cli, bluebook: bluebook, options: options.merge(audience(runtime, launcher)))
          public_names(cli[:names][:command], cli[:commands]) + public_names(cli[:names][:question], cli[:questions])
        end

        # @return [Array<String>] the names whose spec is not internal
        def public_names(names, specs)
          names.reject { |_, id| specs.dig(id, :internal) }.keys.sort
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
end
