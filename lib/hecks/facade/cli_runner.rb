require "json"
require_relative "cli_door"
require_relative "command_request"
require_relative "json_door"
require_relative "launcher_options"
require_relative "../projector"
require_relative "../ports/clock"

module Hecks
  module Facade
    # Parses and dispatches a command line against a `Projector::CliProjector` projection.
    # Does no IO: it answers `[text, status]` and leaves printing and exiting to `bin/` scripts.
    module CliRunner
      module_function

      # Runs one command line against a booted domain and answers the text to print.
      # The booted domain's own chapter is projected, or an attached one its first word names.
      #
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted domain
      # @param argv [Array<String>] an optional `ask`, the verb or question name, then
      #   `path=value` pairs; `--help`, `-h`, `help` or nothing answers usage
      # @param program [String] how the caller was invoked, echoed in usage and hints
      # @return [Array(String, Integer)] the text and the status: 0 answered, 1 refused or misused
      # @raise [Runtime::WiringError] if a repository or the clock adapter cannot be resolved
      # @raise [Runtime::StaleWrite] if concurrent writers beat the command through every retry
      def call(runtime:, argv:, program: "bin/run")
        bluebook, argv, program = chapter_for(runtime, argv, program)
        launcher = LauncherOptions.settings(runtime, bluebook.name)
        options  = { program: program, names: launcher && launcher[:names] }
        cli = Projector.call(:cli, bluebook: bluebook, options: options)

        name = argv.first
        return [cli[:usage], 0] if name.nil? || %w[--help -h help].include?(name)

        # `ask` gives questions their own namespace; a chapter may declare a command and query
        # of one name.
        asking = name == "ask"
        argv   = argv[1..] if asking
        name   = argv.first
        return [cli[:usage], 1] if name.nil?

        # A question answers to its bare name too; `ask` is needed only when a command shares it.
        asking ||= !cli[:names][:command].key?(name) && cli[:names][:question].key?(name)

        # The alias map lets `create_pizza` and `order.create_pizza` reach the same verb.
        pool = asking ? cli[:questions] : cli[:verbs]
        key  = cli[:names][asking ? :question : :command][name]
        spec = pool[key]
        return [unknown(cli, name, asking, program), 1] unless spec

        rest = argv[1..]
        if rest.include?("--help")
          help = Projector.call(:cli, bluebook: bluebook,
                                      options:  options.merge(verb: name, ask: asking))[:usage]
          return [help, 0]
        end

        dispatch(runtime, spec, name, rest, program, asking, bluebook: bluebook, launcher: launcher)
      end

      # The chapter a command line speaks to: the booted domain's own, or, when the first word
      # names a chapter its hecksagon attaches or uses as a framework member (`deploy`,
      # `governance`), that chapter, with the word dropped and added to the program name.
      def chapter_for(runtime, argv, program)
        own      = runtime.registry.bluebooks.values.first
        attached = Array(runtime.registry.hecksagon(own.name)&.member_chapters)
        target   = attached.find { |name| Naming.snake(name) == argv.first }
        return [own, argv, program] unless target

        [runtime.registry.bluebook(target), argv[1..], "#{program} #{argv.first}"]
      end

      # Parses one resolved verb's arguments, runs it as a query or command, and turns the
      # outcome, or the domain's refusal, into `[json_or_message, status]`.
      #
      # @param bluebook [Bluebook::Chapter] the chapter the verb belongs to
      # @param launcher [Hash, nil] the chapter's `launcher` world setting; nil when not opted in
      def dispatch(runtime, spec, name, rest, program, asking, bluebook: nil, launcher: nil)
        rest, wait = LauncherOptions.take_wait(spec, rest) if launcher
        args = stamp_time(runtime, spec, CliDoor.arguments(spec, rest))

        if spec[:kind] == :query
          rows = runtime.query(spec[:verb], **args)
          return [text_answer(rows) || JSON.pretty_generate(rows.map { |row| JsonDoor.materialize(row) }), 0]
        end

        args, minted = LauncherOptions.run_key(runtime, spec, args, launcher)
        # Answers with only this verb's outcome; a full store dump is every record there is.
        request = CommandRequest.normalize(args, receiver:        spec[:receiver],
                                                 legacy_receiver: spec[:legacy_receiver])
        handle = runtime.dispatch_flat(spec[:verb], request)
        extra  = refused_answer(handle)
        extra  = { run: minted }.merge(extra) if minted
        return settled(runtime, spec, handle, bluebook, launcher, extra) if wait
        return [JSON.pretty_generate(answered(handle).merge(extra)), 0] if handle.state.nil?

        [JSON.pretty_generate({ id:     handle.id,
                                state:  JsonDoor.materialize(handle.state),
                                events: handle.events.map(&:name) }.merge(extra)), 0]
      rescue Runtime::NotFound, Runtime::TypeMismatch => e
        # A bad argument and a missing record both need the same next step: read the help.
        ["#{e.message}\n\n  #{program} #{'ask ' if asking}#{name} --help", 1]
      rescue *Runtime::DOMAIN_REFUSALS => e
        # The refusal is the chapter's own sentence, verbatim.
        [e.message, 1]
      end

      # The answer `--wait` gives: the record re-read from its repository after every reaction
      # has run, with all its events, and a status of 1 when its lifecycle ended in a failure
      # state or a reaction the domain refused blocks the run.
      #
      # A refusal blocks unless a sibling reaction to the same event delivered another command on
      # the same aggregate (`Runtime::ReactionOutcome`): a given-gated policy pair, one of which
      # always declines, stays a pass. The refusal is shown under `refused_reactions` either way.
      #
      # @return [Array(String, Integer)] the JSON and the status
      def settled(runtime, spec, handle, bluebook, launcher, extra)
        blocked = blocked?(handle)
        return [JSON.pretty_generate(answered(handle).merge(extra)), blocked ? 1 : 0] if handle.state.nil?

        aggregate = aggregate_of(bluebook, spec)
        state     = reread(runtime, bluebook, aggregate, handle) || handle.state
        fqn       = "#{bluebook.name}::#{aggregate&.hecks_name}"
        events    = runtime.events.select { |event| event.aggregate == fqn && event.id == handle.id }
        answer    = { id: handle.id, state: JsonDoor.materialize(state),
                      events: (events.empty? ? handle.events : events).map(&:name) }.merge(extra)
        failed = blocked || LauncherOptions.failed?(aggregate, state, launcher)
        [JSON.pretty_generate(answer), failed ? 1 : 0]
      end

      # Whether a reaction the domain refused blocks the run the handle reports.
      def blocked?(handle)
        handle.respond_to?(:blocking_reactions) && !handle.blocking_reactions.empty?
      end

      # The aggregate a top-level command belongs to; nil for an entity command or a port.
      def aggregate_of(bluebook, spec)
        head = spec[:verb].split("::", 2).last
        return if head.count(".") != 1

        bluebook.aggregates.find { |aggregate| aggregate.hecks_name == head.split(".").first }
      end

      # The record as its repository holds it now, or nil when it cannot be read.
      def reread(runtime, bluebook, aggregate, handle)
        return unless aggregate && runtime.respond_to?(:registry)

        runtime.registry.repository(bluebook.name, aggregate)&.find(handle.id)&.to_h
      end

      # The text a query answered by a port gave, when that is the whole answer.
      #
      # A query that returns a value object of the single String attribute `text` (the `Document`
      # shape) answers one document; printing it raw keeps the document (JSON, Markdown,
      # sentences) readable and pipeable instead of quoted inside another JSON document.
      #
      # @param rows [Array<Hash>] the query's rows
      # @return [String, nil] the text, or nil when the rows are anything else
      def text_answer(rows)
        return unless rows.length == 1 && rows.first.keys == [:text]
        return unless rows.first[:text].is_a?(String)

        rows.first[:text]
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

      # The reactions one dispatch caused that the domain refused, as `refused_reactions:`.
      #
      # A policy's trigger that a `given` refuses is not the command's own refusal: the command
      # has already persisted. The dispatch result carries them (`Result#refused_reactions`);
      # without this the answer would say nothing of it. A defect (a crash) is warned elsewhere.
      #
      # @param handle [Runtime::Dispatcher::Result, Runtime::RemoteDispatcher::Result] the outcome
      # @return [Hash] `refused_reactions:` each with the `policy`, its `trigger` and the `reason`;
      #   empty when every reaction was delivered (or a remote host sent no per-step log)
      def refused_answer(handle)
        refused = handle.respond_to?(:refused_reactions) ? handle.refused_reactions : []
        refused.empty? ? {} : { refused_reactions: refused }
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
