require "json"
require_relative "cli"
require_relative "command_request"
require_relative "context_line"
require_relative "exit_status"
require_relative "write_guard"
require_relative "ledger_forward"
require_relative "json"
require_relative "launcher_options"
require_relative "read_only_question"
require_relative "newcomer"
require_relative "../../projector"
require_relative "../../ports/clock"
require_relative "cli_runner/answers"
require_relative "cli_runner/resolution"
require_relative "cli_runner/attached_commands"
require_relative "cli_runner/run_replay"
require_relative "cli_runner/search_words"
require_relative "cli_runner/completion_words"
require_relative "cli_runner/tour_words"
require_relative "cli_runner/resume_words"
require_relative "cli_runner/word_help"
require_relative "cli_runner/json_words"
require_relative "cli_runner/settling"
require_relative "cli_runner/streaming"
require_relative "cli_runner/suggestions"
require_relative "cli_runner/verb_names"
require_relative "cli_runner/renamed_names"
require_relative "cli_runner/verbosity"
require_relative "cli_runner/name_index"

module Hecks
  module Adapters
    module Driving
      # Parses and dispatches a command line against a `Projector::CliProjector` projection.
      # Does no IO: it answers `[text, status]` (an `ExitStatus`) and leaves printing and exiting
      # to its callers.
      module CliRunner
        include ExitStatus
        extend Verbosity

        # The class an adapter raises when the tool it wraps refuses.
        TOOL_REFUSAL = "Hecks::Adapters::ConsoleCapture::Failure".freeze
        # The words that open the query namespace; `ask` is the older spelling.
        QUERY_WORDS = %w[query ask].freeze

        extend Resolution
        extend AttachedCommands
        extend SearchWords
        extend CompletionWords
        extend TourWords
        extend ResumeWords
        extend WordHelp
        extend JsonWords
        extend Suggestions
        extend NameIndex
        extend VerbNames
        extend RenamedNames
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
          level, argv = split_verbosity(argv)
          return [Verbosity::CONFLICT, USAGE] if level == :conflict

          with_verbosity(level) { answer_line(runtime, argv, program, usage_log, err) }
        rescue Interrupt
          [interrupted(argv), ExitStatus::REFUSED]
        end

        # Answers one line: resolves it, guards a write, dispatches it and records its usage.
        #
        # @api private
        # @return [Array(String, Integer)] the text and the `ExitStatus`
        def answer_line(runtime, argv, program, usage_log, err)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          plan = resolve(runtime, argv, program)
          return plan[:answer] if plan[:answer]

          guarded = guard_command(plan, argv, err, runtime)
          return guarded if guarded

          answer = dispatch(runtime, plan[:spec], plan[:name], plan[:rest], plan[:program], plan[:asking],
                            bluebook: plan[:bluebook], launcher: plan[:launcher])
          finish_line(answer, plan, started, { argv: argv, usage_log: usage_log, err: err })
        end

        # Records a line that ran and prints its details when `-v` asked for them.
        #
        # @api private
        # @return [Array(String, Integer)] the answer, unchanged
        def finish_line(answer, plan, started, details)
          UsageLog.record(argv: details[:argv], resolved: plan[:name], status: answer[1], started: started) if details[:usage_log]
          verbose_details(details[:err], plan[:name], started) if verbose?
          answer
        end

        # The line an interrupted command ends with: what it was and that it was not finished,
        # so the caller sees a refusal rather than a bare stop.
        #
        # @api private
        # @return [String] the text the caller prints on standard error
        def interrupted(argv)
          name = argv.first || "the command"
          "interrupted during #{name}: the run was stopped before it finished"
        end

        # Before a command (not a query) runs: a write that would land in Memory from a worktree
        # whose main checkout stores it elsewhere runs in the main checkout (or is refused, when
        # forwarding is off); any other command prints the context line and runs here.
        #
        # @api private
        # @return [Array(String, Integer), nil] the answer of a forwarded or refused write, or nil
        #   when the command may run here
        def guard_command(plan, argv, err, runtime)
          return if plan[:asking]

          forwarded = LedgerForward.call(plan, argv, err, runtime: runtime)
          return forwarded if forwarded

          ContextLine.announce(err) unless quiet?
          nil
        end

        # The names a person can type at the launcher, as the projection names them: commands and
        # queries, leaving out the internal steps a run records about itself.
        #
        # @param runtime [#registry] a booted domain, or what `Hecks.describe` answers
        # @param program [String] how the caller was invoked
        # @return [Array<String>] the sorted names
        def known_names(runtime:, program: "hecks run")
          cli = projected(runtime, program)
          public_names(cli[:names][:command], cli[:commands]) + public_names(cli[:names][:question], cli[:questions])
        end

        # The names a person can type to run a command, leaving out the questions and the internal
        # steps: what an MCP server's `dispatch` can be given.
        #
        # @param runtime [#registry] a booted domain, or what `Hecks.describe` answers
        # @param program [String] how the caller was invoked
        # @return [Array<String>] the sorted names
        def known_command_names(runtime:, program: "hecks run")
          cli = projected(runtime, program)
          public_names(cli[:names][:command], cli[:commands])
        end

        # @api private
        # @return [Hash] the CLI projection of the domain's own bluebook
        def projected(runtime, program)
          bluebook, = bluebook_for(runtime, [], program)
          launcher = LauncherOptions.settings(runtime, bluebook.name)
          options = LauncherOptions.projection(launcher, program)
          Projector.call(:cli, bluebook: bluebook, options: options.merge(audience(runtime, launcher)))
        end

        # @return [Array<String>] the names whose spec is not internal
        def public_names(names, specs)
          names.reject { |_, id| specs.dig(id, :internal) }.keys.sort
        end

        # Whether the line is a resume that names a run. It runs a saga, so it needs a booted
        # domain: the usage path answers nothing for it, and the launcher boots and calls `call`.
        # A resume with no run, or one that asks for help, is still only a request for usage.
        #
        # @api private
        # @param argv [Array<String>] the line, without its verbosity flags
        # @return [Boolean]
        def runs_a_saga?(argv)
          argv.first == "resume" && !argv[1].nil? && !argv.drop(1).intersect?(Resolution::HELP_WORDS)
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
          level, argv = split_verbosity(argv)
          return [Verbosity::CONFLICT, USAGE] if level == :conflict
          return if runs_a_saga?(argv)

          UsageCache.fetch(runtime, argv, program, audience: audience_key) { resolve(runtime, argv, program)[:answer] }
        end
      end
    end
  end
end
