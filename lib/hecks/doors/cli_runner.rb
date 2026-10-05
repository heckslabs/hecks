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

        dispatch(runtime, plan[:spec], plan[:name], plan[:rest], plan[:program], plan[:asking],
                 bluebook: plan[:bluebook], launcher: plan[:launcher])
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
      def stream(runtime:, argv:, program: "hecks run", out: $stdout, err: $stderr, max_polls: nil)
        plan = resolve(runtime, argv, program)
        return if plan[:answer] || !LauncherOptions.streams?(plan[:launcher], plan[:spec])

        words, streaming = LauncherOptions.take_stream(plan[:rest])
        return unless streaming

        tail(runtime, plan[:spec], CliDoor.arguments(plan[:spec], words), out, max_polls)
        0
      rescue Interrupt, Errno::EPIPE
        0
      rescue Runtime::NotFound, Runtime::TypeMismatch => e
        err.puts("#{e.message}\n\n  #{program} #{plan[:name]} --help")
        1
      rescue *Runtime::DOMAIN_REFUSALS => e
        err.puts(e.message)
        1
      end

      # One ask after another, each from the cursor the last gave.
      def tail(runtime, spec, args, out, max_polls)
        args   = args.merge(wait: { value: 30 }) unless args.key?(:wait)
        polls  = 0
        cursor = nil
        loop do
          ask  = cursor ? args.except(:from_now).merge(since: { value: cursor }) : args
          rows = runtime.query(spec[:command], **ask)
          row  = rows.first || {}
          Array(row[:events]).each { |event| out.puts(JSON.generate(entry_line(JsonDoor.materialize(event)))) }
          out.flush
          cursor = row[:cursor]
          polls += 1
          break if cursor.nil? || (max_polls && polls >= max_polls)
        end
      end

      # An entry as a line: its payload, which the answer holds as JSON text, back as an object.
      def entry_line(event)
        line = JSON.parse(JSON.generate(event))
        line["payload"] = JSON.parse(line["payload"]) if line["payload"].is_a?(String)
        line
      rescue JSON::ParserError
        line
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
        bluebook, argv, program = chapter_for(runtime, argv, program)
        launcher = LauncherOptions.settings(runtime, bluebook.name)
        options  = LauncherOptions.projection(launcher, program)
        cli = Projector.call(:cli, bluebook: bluebook, options: options)

        name = argv.first
        return { answer: [cli[:usage], 0] } if name.nil? || %w[--help -h help].include?(name)
        return { answer: [all_usage(bluebook, options), 0] } if name == "--all"

        asking, name, argv = entry_word(cli, argv)
        return { answer: [cli[:usage], 1] } if name.nil?

        # The alias map lets `create_pizza` and `order.create_pizza` reach the same command.
        pool = asking ? cli[:questions] : cli[:commands]
        key  = cli[:names][asking ? :question : :command][name]
        spec = pool[key]
        return { answer: [unknown(cli, name, asking, program), 1] } unless spec

        rest = argv[1..]
        if rest.include?("--help")
          help = Projector.call(:cli, bluebook: bluebook,
                                      options:  options.merge(command: name, ask: asking))[:usage]
          return { answer: [help, 0] }
        end

        { spec: spec, name: name, rest: rest, asking: asking, program: program, bluebook: bluebook,
          launcher: launcher }
      end

      # The usage with the internal commands and queries listed too, which `--all` asks for.
      def all_usage(bluebook, options)
        Projector.call(:cli, bluebook: bluebook, options: options.merge(all: true))[:usage]
      end

      # Reads the entry words of a line: whether it asks a query, the bare name, and the words
      # from the name on.
      #
      # `query` gives queries their own namespace (`ask` is its older spelling); a chapter may
      # declare a command and a query of one name. A trailing `!` says the word is a command and
      # is not part of the name. A query answers to its bare name too; `query` is needed only when
      # a command shares it.
      #
      # @return [Array(Boolean, String, Array<String>)] `asking`, `name` (nil when absent), `argv`
      def entry_word(cli, argv)
        asking = QUERY_WORDS.include?(argv.first)
        argv   = argv[1..] if asking
        name   = argv.first
        return [asking, nil, argv] if name.nil?

        bang = name.end_with?("!")
        name = name.chomp("!") if bang
        asking ||= !bang && !cli[:names][:command].key?(name) && cli[:names][:question].key?(name)
        [asking, name, argv]
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

      # Parses one resolved command's arguments, runs it as a query or command, and turns the
      # outcome, or the domain's refusal, into `[json_or_message, status]`. With `--wait`, a
      # question whose report names a gap (`LauncherOptions.gap_reported?`) answers status 1.
      #
      # @param bluebook [Bluebook::Chapter] the chapter the command belongs to
      # @param launcher [Hash, nil] the chapter's `launcher` world setting; nil when not opted in
      def dispatch(runtime, spec, name, rest, program, asking, bluebook: nil, launcher: nil)
        rest, wait = LauncherOptions.take_wait(spec, rest) if launcher
        wait ||= LauncherOptions.settled?(launcher, spec)
        args = CliDoor.arguments(spec, rest)

        return answer_query(runtime, spec, args, wait) if spec[:kind] == :query

        args, minted = LauncherOptions.run_key(runtime, spec, args, launcher)
        # Answers with only this command's outcome; a full store dump is every record there is.
        request = CommandRequest.normalize(args, receiver:        spec[:receiver],
                                                 legacy_receiver: spec[:legacy_receiver])
        handle = runtime.dispatch_flat(spec[:command], request)
        extra  = refused_answer(handle)
        extra  = { run: minted }.merge(extra) if minted
        return settled(runtime, spec, handle, bluebook, launcher, extra) if wait
        return [JSON.pretty_generate(answered(handle).merge(extra)), 0] if handle.state.nil?

        [JSON.pretty_generate({ id:     handle.id,
                                state:  JsonDoor.materialize(handle.state),
                                events: handle.events.map(&:name) }.merge(extra)), 0]
      rescue Runtime::NotFound, Runtime::TypeMismatch => e
        # A bad argument and a missing record both need the same next step: read the help.
        ["#{e.message}\n\n  #{program} #{'query ' if asking}#{name} --help", 1]
      rescue *Runtime::DOMAIN_REFUSALS => e
        # The refusal is the chapter's own sentence, verbatim.
        [e.message, 1]
      rescue StandardError => e
        # So is a wrapped tool's, when a question's adapter refuses to answer. Matched by name: the
        # adapters belong to the Hecks chapter, which a client's runtime never loads.
        raise unless e.class.ancestors.map(&:name).include?(TOOL_REFUSAL)

        [e.message, 1]
      end

      # Runs a question and answers its rows, or its text when an adapter answered in text.
      #
      # @param wait [Boolean, nil] whether `--wait` was given: a report naming a gap then fails
      # @return [Array(String, Integer)] the answer and the status
      def answer_query(runtime, spec, args, wait)
        rows = runtime.query(spec[:command], **args)
        text = text_answer(spec, rows)
        [text || JSON.pretty_generate(rows.map { |row| JsonDoor.materialize(row) }),
         wait && LauncherOptions.gap_reported?(text) ? 1 : 0]
      end

      # The answer `--wait` gives: the record re-read after every reaction has run, with all its
      # events, and a status of 1 when its lifecycle ended in a failure state, a refused reaction
      # blocks the run or a reaction crashed.
      #
      # A refusal blocks unless a sibling reaction delivered another command on the same
      # aggregate (`Runtime::ReactionOutcome`). The settled record is always the text, so a failed
      # run pipes like a passing one; the reason a human reads is a third element.
      #
      # @return [Array(String, Integer)] the JSON and the status, plus (Array(String, Integer,
      #   String)) why the run failed when it did
      def settled(runtime, spec, handle, bluebook, launcher, extra)
        why = reactions_failed(handle)
        return finish(JSON.pretty_generate(answered(handle).merge(extra)), why) if handle.state.nil?

        aggregate = aggregate_of(bluebook, spec)
        state     = reread(runtime, bluebook, aggregate, handle) || handle.state
        fqn       = "#{bluebook.name}::#{aggregate&.hecks_name}"
        events    = runtime.events.select { |event| event.aggregate == fqn && event.id == handle.id }
        answer    = { id: handle.id, state: JsonDoor.materialize(state),
                      events: (events.empty? ? handle.events : events).map(&:name) }.merge(extra)
        if LauncherOptions.failed?(aggregate, state, launcher)
          field = aggregate.lifecycle.field
          why  += [failure_sentence(aggregate, state, field)]
        end
        finish(JSON.pretty_generate(answer), why)
      end

      # The sentence for a record that ended in a failure state: the state, then the record's own
      # `refusal` when it keeps one, without the class name an adapter's failure carries.
      def failure_sentence(aggregate, state, field)
        sentence = "#{aggregate.hecks_name} ended in the failure state #{state[field.to_sym].to_s.inspect}"
        refusal  = state[:refusal]
        refusal  = refusal.value if refusal.respond_to?(:value)
        refusal  = refusal[:value] if refusal.is_a?(Hash)
        return sentence if refusal.to_s.strip.empty?

        "#{sentence}: #{refusal.to_s.strip.sub(/\A(\w+::)+\w+: /, '')}"
      end

      # The answer and its status: 0 when nothing failed, else 1 with the reasons joined.
      def finish(text, reasons)
        reasons.empty? ? [text, 0] : [text, 1, reasons.join("\n")]
      end

      # What the reactions of the run the handle reports did wrong: each refusal that blocks it
      # and each crash, as one sentence apiece.
      def reactions_failed(handle)
        blocking = handle.respond_to?(:blocking_reactions) ? handle.blocking_reactions : []
        crashed  = handle.respond_to?(:reaction_defects) ? handle.reaction_defects : []
        blocking.map { |row| "reaction #{row[:policy]} was refused (#{row[:trigger]}): #{row[:reason]}" } +
          crashed.map { |row| "reaction #{row[:policy]} crashed (#{row[:error_class]}): #{row[:reason]}" }
      end

      # Whether a reaction the domain refused blocks the run the handle reports.
      def blocked?(handle)
        handle.respond_to?(:blocking_reactions) && !handle.blocking_reactions.empty?
      end

      # The aggregate a top-level command belongs to; nil for an entity command or a port.
      def aggregate_of(bluebook, spec)
        head = spec[:command].split("::", 2).last
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
      # A query declared `returns Document` (one value object of the single String attribute
      # `text`) answers one document; printing it raw keeps the document (JSON, Markdown,
      # sentences) readable and pipeable instead of quoted inside another JSON document. What a
      # query declares decides it, not how many rows came back: any other query prints JSON,
      # so a script reading it sees an array whether it held one row or two.
      #
      # @param spec [Hash] the question's projected spec
      # @param rows [Array<Hash>] the query's rows
      # @return [String, nil] the text, or nil when the query does not return a Document
      def text_answer(spec, rows)
        return unless spec[:returns] == "Document" && rows.length == 1 && rows.first.keys == [:text]
        return unless rows.first[:text].is_a?(String)

        rows.first[:text]
      end

      # The reactions one dispatch caused that the domain refused, as `refused_reactions:`.
      #
      # A policy's trigger that a `given` refuses is not the command's own refusal: the command
      # has already persisted. The dispatch result carries them (`Result#refused_reactions`);
      # without this the answer would say nothing of it. A defect (a crash) is shown apart, as
      # `reaction_defects:`, and fails `--wait`.
      #
      # @param handle [Runtime::Dispatcher::Result, Runtime::RemoteDispatcher::Result] the outcome
      # @return [Hash] `refused_reactions:` each with the `policy`, its `trigger` and the `reason`;
      #   empty when every reaction was delivered (or a remote host sent no per-step log), plus
      #   `reaction_defects:` when one crashed
      def refused_answer(handle)
        refused = handle.respond_to?(:refused_reactions) ? handle.refused_reactions : []
        defects = handle.respond_to?(:reaction_defects) ? handle.reaction_defects : []
        answer  = refused.empty? ? {} : { refused_reactions: refused }
        defects.empty? ? answer : answer.merge(reaction_defects: defects)
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

      # Words the answer for an unknown command or question, suggesting up to five near names.
      # Ranked by shared prefix, which survives a dropped letter where a substring match would not.
      def unknown(cli, name, asking, program)
        # Both spellings are candidates: `order.create_piza` shares no prefix with `create_pizza`.
        pool = cli[:names][asking ? :question : :command].keys
        # A bare name is the commonest slip now that the aggregate is required: its homes first.
        homes = (pool + cli[:names][asking ? :command : :question].keys)
                .select { |candidate| candidate.split(".").last == name }.uniq
        similar = pool.map { |candidate| [shared_prefix(candidate, name), candidate] }
                      .select { |shared, _| shared >= [name.length / 2, 3].max }
                      .sort_by { |shared, candidate| [-shared, candidate] }
                      .map(&:last)
        near = homes + (similar - homes)

        lines = ["no such #{asking ? 'query' : 'command'}: #{name}"]
        lines += ["", "did you mean:", *near.first(5).map { |candidate| "  #{candidate}" }] unless near.empty?
        lines += ["", "  #{program}#{' query' if asking}   for the full list"]
        lines.join("\n")
      end

      def shared_prefix(one, other)
        length = [one.length, other.length].min
        (0...length).find { |index| one[index] != other[index] } || length
      end
    end
  end
end
