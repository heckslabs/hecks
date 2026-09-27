require "json"
require_relative "cli_door"
require_relative "command_request"
require_relative "json_door"
require_relative "../projector"
require_relative "../ports/clock"

module Hecks
  module Facade
    # Parses and dispatches a command line against a `Projector::CliProjector` projection.
    # Does no IO: it answers `[text, status]` and leaves printing and exiting to `bin/` scripts.
    module CliRunner
      module_function

      # Runs one command line against a booted domain and answers the text to print.
      # Only the first bluebook in the registry, the booted domain's own, is projected.
      #
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted domain
      # @param argv [Array<String>] an optional `ask`, the verb or question name, then
      #   `path=value` pairs; `--help`, `-h`, `help` or nothing answers usage
      # @param program [String] how the caller was invoked, echoed in usage and hints
      # @return [Array(String, Integer)] the text and the status: 0 answered, 1 refused or misused
      # @raise [Runtime::WiringError] if a repository or the clock adapter cannot be resolved
      # @raise [Runtime::StaleWrite] if concurrent writers beat the command through every retry
      def call(runtime:, argv:, program: "bin/run")
        bluebook = runtime.registry.bluebooks.values.first
        cli      = Projector.call(:cli, bluebook: bluebook, options: { program: program })

        name = argv.first
        return [cli[:usage], 0] if name.nil? || %w[--help -h help].include?(name)

        # `ask` gives questions their own namespace; a chapter may declare a command and query
        # of one name.
        asking = name == "ask"
        argv   = argv[1..] if asking
        name   = argv.first
        return [cli[:usage], 1] if name.nil?

        # The alias map lets `create_pizza` and `order.create_pizza` reach the same verb.
        pool = asking ? cli[:questions] : cli[:verbs]
        key  = cli[:names][asking ? :question : :command][name]
        spec = pool[key]
        return [unknown(cli, name, asking, program), 1] unless spec

        rest = argv[1..]
        if rest.include?("--help")
          help = Projector.call(:cli, bluebook: bluebook,
                                      options:  { program: program, verb: name, ask: asking })[:usage]
          return [help, 0]
        end

        dispatch(runtime, spec, name, rest, program, asking)
      end

      # Parses one resolved verb's arguments, runs it as a query or command, and turns the
      # outcome, or the domain's refusal, into `[json_or_message, status]`.
      def dispatch(runtime, spec, name, rest, program, asking)
        args = stamp_time(runtime, spec, CliDoor.arguments(spec, rest))

        if spec[:kind] == :query
          rows = runtime.query(spec[:verb], **args)
          return [JSON.pretty_generate(rows.map { |row| JsonDoor.materialize(row) }), 0]
        end

        # Answers with only this verb's outcome; a full store dump is every record there is.
        request = CommandRequest.normalize(args, receiver:        spec[:receiver],
                                                 legacy_receiver: spec[:legacy_receiver])
        handle = runtime.dispatch_flat(spec[:verb], request)
        return [JSON.pretty_generate(answered(handle)), 0] if handle.state.nil?

        [JSON.pretty_generate(id:     handle.id,
                              state:  JsonDoor.materialize(handle.state),
                              events: handle.events.map(&:name)), 0]
      rescue Runtime::NotFound, Runtime::TypeMismatch => e
        # A bad argument and a missing record both need the same next step: read the help.
        ["#{e.message}\n\n  #{program} #{'ask ' if asking}#{name} --help", 1]
      rescue *Runtime::DOMAIN_REFUSALS => e
        # The refusal is the chapter's own sentence, verbatim.
        [e.message, 1]
      end

      # Fills in a `now` argument the caller left out, from the clock port; an explicit one wins.
      #
      # Done at the door, not in the runtime: a clock read inside the interpreter would give a
      # replayed corpus step the replay day's time. Matched by the argument's name alone.
      def stamp_time(runtime, spec, args)
        return args unless spec[:arguments].any? { |argument| argument[:path].start_with?("now.") }
        return args if args.key?(:now)

        args.merge(now: { value: Ports::Clock.now(runtime.registry) })
      end

      # Shapes a port operation's outcome, which has no state: each event with its full payload.
      #
      # The answer lives only in the payloads, so names alone would drop it. Exit status stays 0
      # for refusal events too, since a healthy no is an answer, not a misuse.
      def answered(handle)
        # A port operation hydrates no instance, so the handle's `id` is nil by design.
        { id:     handle.id || handle.events.first&.id,
          events: handle.events.map do |event|
            { name: event.name, payload: JsonDoor.materialize(event.payload) }
          end }
      end

      # Words the answer for an unknown verb or question, suggesting up to five near names.
      # Ranked by shared prefix, which survives a dropped letter where a substring match would not.
      def unknown(cli, name, asking, program)
        # Both spellings are candidates: `order.create_piza` shares no prefix with `create_pizza`.
        pool = cli[:names][asking ? :question : :command].keys
        near = pool.map    { |candidate| [shared_prefix(candidate, name), candidate] }
                   .select { |shared, _| shared >= [name.length / 2, 3].max }
                   .sort_by { |shared, candidate| [-shared, candidate] }
                   .map(&:last)

        lines = ["no such #{asking ? 'question' : 'verb'}: #{name}"]
        lines += ["", "did you mean:", *near.first(5).map { |candidate| "  #{candidate}" }] unless near.empty?
        lines += ["", "  #{program}#{' ask' if asking}   for the full list"]
        lines.join("\n")
      end

      def shared_prefix(one, other)
        length = [one.length, other.length].min
        (0...length).find { |index| one[index] != other[index] } || length
      end
    end
  end
end
