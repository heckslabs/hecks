require "json"
require_relative "cli_door"
require_relative "command_request"
require_relative "json_door"
require_relative "launcher_options"
require_relative "../projector"
require_relative "../ports/clock"

module Hecks
  module Doors
    # Parses and dispatches a command line against a `Projector::CliProjector` projection.
    # Does no IO: it answers `[text, status]` and leaves printing and exiting to its callers.
    module CliRunner
      # The class an adapter raises when the tool it wraps refuses.
      TOOL_REFUSAL = "Hecks::Adapters::ConsoleCapture::Failure".freeze
      # The words that open the query namespace; `ask` is the older spelling.
      QUERY_WORDS = %w[query ask].freeze

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

        dispatch(runtime, plan)
      end

      # Tails a question: asks, prints each new entry as one JSON line, and asks again from the
      # cursor the answer gave, until the reader interrupts. Only for a question the `launcher`
      # setting lists under `streams`, given `--stream`; `from_now` applies to the first ask only.
      #
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted domain
      # @param argv [Array<String>] as for `call`, with `--stream`
      # @param program [String] how the caller was invoked
      # @param out [IO] where each entry's line goes
      # @param err [IO] where a refusal goes
      # @param max_polls [Integer, nil] stop after this many asks; unbounded when nil
      # @return [Integer, nil] 0 or 1 for a stream, nil when `call` should run the line
      # rubocop:disable Metrics/ParameterLists -- keywords are the public call shape callers pass
      def stream(runtime:, argv:, program: "hecks run", out: $stdout, err: $stderr, max_polls: nil)
        # rubocop:enable Metrics/ParameterLists
        Streaming.run(runtime, argv, program, Streaming::Sink.new(out, err, max_polls))
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
        UsageCache.fetch(runtime, argv, program) { resolve(runtime, argv, program)[:answer] }
      end

      # Parses a command line against the projection: either the answer it gives without
      # running anything, or the command it would run.
      #
      # @return [Hash] `{answer: [text, status]}`, or `{spec:, name:, rest:, asking:, program:,
      #   bluebook:, launcher:}` for a command to dispatch
      def resolve(runtime, argv, program)
        Resolution.call(runtime, argv, program)
      end

      # Parses one resolved command's arguments, runs it as a query or command, and turns the
      # outcome, or the domain's refusal, into `[json_or_message, status]`. With `--wait`, a
      # question whose report names a gap (`LauncherOptions.gap_reported?`) answers status 1.
      #
      # @param plan [Hash] what `resolve` answered for a command to dispatch
      def dispatch(runtime, plan)
        run_command(runtime, plan)
      rescue Runtime::NotFound, Runtime::TypeMismatch => e
        # A bad argument and a missing record both need the same next step: read the help.
        ["#{e.message}\n\n  #{plan[:program]} #{"query " if plan[:asking]}#{plan[:name]} --help", 1]
      rescue *Runtime::DOMAIN_REFUSALS => e
        # The refusal is the chapter's own sentence, verbatim.
        [e.message, 1]
      rescue StandardError => e
        # So is a wrapped tool's, when a question's adapter refuses to answer. Matched by name: the
        # adapters belong to the Hecks chapter, which a client's runtime never loads.
        raise unless e.class.ancestors.map(&:name).include?(TOOL_REFUSAL)

        [e.message, 1]
      end

      # Parses the command's arguments and runs it as a question or a command.
      def run_command(runtime, plan)
        spec     = plan[:spec]
        launcher = plan[:launcher]
        rest, wait = LauncherOptions.take_wait(spec, plan[:rest]) if launcher
        wait ||= LauncherOptions.settled?(launcher, spec)
        args = CliDoor.arguments(spec, rest || plan[:rest])
        return Answers.query(runtime, spec, args, wait) if spec[:kind] == :query

        issue(runtime, plan, args, wait)
      end

      # Dispatches a command and answers its outcome, settled first when `--wait` was given.
      def issue(runtime, plan, args, wait)
        spec = plan[:spec]
        args, minted = LauncherOptions.run_key(runtime, spec, args, plan[:launcher])
        request = CommandRequest.normalize(args, receiver:        spec[:receiver],
                                                 legacy_receiver: spec[:legacy_receiver])
        handle = runtime.dispatch_flat(spec[:command], request)
        extra  = Answers.refused_answer(handle)
        extra  = { run: minted }.merge(extra) if minted
        return Answers.plain(handle, extra) unless wait

        Settling.call(Settling::Context.new(runtime, spec, plan[:bluebook], plan[:launcher]), handle, extra)
      end

      # The answer `--wait` gives for a settled command; see `Settling.call`.
      #
      # @return [Array(String, Integer)] the JSON and the status, plus (Array(String, Integer,
      #   String)) why the run failed when it did
      # rubocop:disable Metrics/ParameterLists -- the argument list is the public call shape
      def settled(runtime, spec, handle, bluebook, launcher, extra)
        # rubocop:enable Metrics/ParameterLists
        Settling.call(Settling::Context.new(runtime, spec, bluebook, launcher), handle, extra)
      end

      # The text a query answered by a port gave, when that is the whole answer; see
      # `Answers.text_answer`.
      def text_answer(spec, rows) = Answers.text_answer(spec, rows)

      # The reactions one dispatch caused that the domain refused; see `Answers.refused_answer`.
      def refused_answer(handle) = Answers.refused_answer(handle)

      # Whether a reaction the domain refused blocks the run the handle reports.
      def blocked?(handle) = Answers.blocked?(handle)
    end
  end
end

require_relative "cli_runner/answers"
require_relative "cli_runner/settling"
require_relative "cli_runner/streaming"
require_relative "cli_runner/suggestions"
require_relative "cli_runner/resolution"
