require "json"
require_relative "cli_door"
require_relative "command_request"
require_relative "json_door"
require_relative "../projector"
require_relative "../ports/clock"

module Hecks
  module Facade
    # The runner behind a projected CLI.
    #
    # `Projector::CliProjector` answers what a domain's command line looks
    # like; this is the twenty lines that parse against it and dispatch. It
    # lives in `lib/` rather than in a `bin/` because more than one front door
    # wants it — `bin/run` for whichever domain you are standing in, `bin/qc`
    # pinned to the QA ledger — and a second copy of the parse-and-dispatch
    # would be the exact duplication the projection exists to avoid.
    #
    # No IO. It answers `[text, status]` and never prints or exits, so a spec
    # can call it without capturing streams or trapping SystemExit. The `bin/`
    # scripts do the printing, the same division `Router` and `JsonDoor`
    # already keep against HTTP.
    module CliRunner
      module_function

      # Runs one command line against a booted domain: resolves the verb or question,
      # parses its `name=value` arguments, dispatches or queries, and answers with the text
      # to print.
      #
      # `[text, status]` — status 0 answered, 1 refused or misused.
      #
      # Only the first bluebook in the registry (the booted domain's own) is projected
      # into verbs. `--help`, `-h`, `help` or an empty `argv` answers the usage text; a
      # verb followed by `--help` answers that verb's help.
      #
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted domain,
      #   as `Hecks.boot` returns it
      # @param argv [Array<String>] the words after the program name: an optional `ask`,
      #   the verb or question name (bare or aggregate-qualified), then `path=value` pairs
      # @param program [String] how the caller was invoked, echoed in usage and hints
      # @return [Array(String, Integer)] the text to print and the exit status: 0 with
      #   usage, help, or pretty-printed JSON of the outcome; 1 with a message when the
      #   verb is unknown, an argument is wrong, a record is missing, or the domain refuses
      # @raise [Runtime::WiringError] if a repository, or the clock adapter a `now`
      #   argument needs, cannot be resolved
      # @raise [Runtime::StaleWrite] if concurrent writers beat the command through every
      #   retry
      def call(runtime:, argv:, program: "bin/run")
        bluebook = runtime.registry.bluebooks.values.first
        cli      = Projector.call(:cli, bluebook: bluebook, options: { program: program })

        name = argv.first
        return [cli[:usage], 0] if name.nil? || %w[--help -h help].include?(name)

        # `ask` puts a question in its own namespace — a chapter may declare a
        # command and a query of one name, and banking does.
        asking = name == "ask"
        argv   = argv[1..] if asking
        name   = argv.first
        return [cli[:usage], 1] if name.nil?

        # Resolved through the alias map, so `pizzas create_pizza` and
        # `pizzas order.create_pizza` reach the same verb — the aggregate is
        # worth typing only when two of them declare the same word.
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

      # Parses one resolved verb's arguments, runs it as a query or a command, and turns
      # the outcome, or the domain's refusal, into printable text.
      #
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted domain
      # @param spec [Hash{Symbol => Object}] the verb's entry from `Projector::CliProjector`;
      #   read for `:kind`, `:verb`, `:arguments`, `:receiver` and `:legacy_receiver`
      # @param name [String] the verb as the caller typed it, echoed in the `--help` hint
      # @param rest [Array<String>] the `path=value` words after the verb
      # @param program [String] how the caller was invoked, echoed in the `--help` hint
      # @param asking [Boolean] whether the verb was reached through `ask`, which only
      #   changes the wording of the hint
      # @return [Array(String, Integer)] status 0 with pretty-printed JSON: the materialized
      #   rows for a query; `id`, `state` and event names for a command; `id` and events
      #   with payloads for a port operation. Status 1 with the message of a
      #   `Runtime::DOMAIN_REFUSALS` error, followed by a `--help` hint when it is a
      #   `Runtime::NotFound` or `Runtime::TypeMismatch`
      # @raise [Runtime::WiringError] if a repository, or the clock adapter a `now`
      #   argument needs, cannot be resolved
      # @raise [Runtime::StaleWrite] if concurrent writers beat the command through every
      #   retry
      def dispatch(runtime, spec, name, rest, program, asking)
        args = stamp_time(runtime, spec, CliDoor.arguments(spec, rest))

        if spec[:kind] == :query
          rows = runtime.query(spec[:verb], **args)
          return [JSON.pretty_generate(rows.map { |row| JsonDoor.materialize(row) }), 0]
        end

        # The answer is scoped to what was asked. `bin/run`'s step-list form
        # reports the whole store because a corpus run is judged on all of it;
        # somebody who issued one verb wants that verb's outcome, and against a
        # Postgres-backed domain the full dump is every record there has been.
        request = CommandRequest.normalize(args, receiver:        spec[:receiver],
                                                 legacy_receiver: spec[:legacy_receiver])
        handle = runtime.dispatch_flat(spec[:verb], request)
        return [JSON.pretty_generate(answered(handle)), 0] if handle.state.nil?

        [JSON.pretty_generate(id:     handle.id,
                              state:  JsonDoor.materialize(handle.state),
                              events: handle.events.map(&:name)), 0]
      rescue Runtime::NotFound, Runtime::TypeMismatch => e
        # A bad argument and a missing record both land here, and both want the
        # same next step: read what the verb actually takes.
        ["#{e.message}\n\n  #{program} #{'ask ' if asking}#{name} --help", 1]
      rescue *Runtime::DOMAIN_REFUSALS => e
        # **The refusal is the product** — the chapter's own sentence, verbatim.
        [e.message, 1]
      end

      # Supplies the current time for a verb that takes a `now` argument the caller left out.
      #
      # The clock, filled in at the door.
      #
      # A staleness rule needs the time, and the sublanguage cannot ask for it
      # — a `given` that read the clock would judge the same record differently
      # on two runs, and every replay, audit and fuzz oracle here assumes it
      # does not. So `now` stays an argument the predicate merely reads, and
      # the question becomes who types it. Left to the caller, that is:
      #
      #   qa/quality_control target.claim id=QC held_by.value=me \
      #     now.value=$(date +%s) window.value=900
      #
      # which is a shell incantation in front of every claim, and one an agent
      # gets wrong by pasting a stale number.
      #
      # At the door, not in the runtime, and the distinction is load-bearing.
      # `Ports::IdentityGeneration` reasons the same question through for a
      # minted uuid and lands on "the value is baked into the caller's args at
      # the first live dispatch". A clock consulted inside the interpreter
      # would not have that property — a recorded corpus step replayed
      # tomorrow would quietly get tomorrow's time, and the fuzzer's oracle and
      # the adapter-agreement gate both compare runs of exactly that shape. Here
      # it fills only what a person or an agent is typing, and `runtime.dispatch`
      # is left alone.
      #
      # An explicit value always wins, so a spec or a caller reproducing a
      # moment says so and is believed. This only supplies what was omitted.
      #
      # By name, which is the one uncomfortable part. `now` is a plausible
      # domain word and nothing declares that it means the clock. It is
      # tolerable because this is a convenience layer rather than semantics —
      # the verb's own help says the argument exists, dispatch is unchanged,
      # and passing it explicitly is always available. The honest version is a
      # declaration in the chapter (`attribute :now, Instant, from: :clock`),
      # which is a language change: DSL, IR, the self-hosted grammar and its
      # goldens. Worth doing; not worth smuggling in here.
      #
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted domain,
      #   whose registry names the clock adapter
      # @param spec [Hash{Symbol => Object}] the verb's projected entry; only an option whose
      #   `:path` starts `"now."` makes this method act
      # @param args [Hash{Symbol => Object}] the parsed arguments; not mutated
      # @return [Hash{Symbol => Object}] `args` itself when the verb takes no `now` or the
      #   caller gave one; otherwise a copy with `now: { value: seconds }`, the clock port's
      #   current time in whole seconds
      # @raise [Runtime::WiringError] if the time is needed and zero or several adapters
      #   implement the clock port
      def stamp_time(runtime, spec, args)
        return args unless spec[:arguments].any? { |argument| argument[:path].start_with?("now.") }
        return args if args.key?(:now)

        args.merge(now: { value: Ports::Clock.now(runtime.registry) })
      end

      # Shapes a port operation's outcome for printing: the record asked about, and each
      # event with its full payload.
      #
      # A port operation has no state, and its payload is the entire point.
      #
      # A command answers with the record it changed, so naming the events is
      # enough — the interesting part is in `state`. A port operation changes
      # no record: it asked something outside and came back with what was
      # said, and that lives only in the event payload. Reporting names alone
      # would print `SpecsCompleted` and drop the spec output on the floor.
      #
      # This is what makes a projected CLI usable as somebody's only door. An
      # agent that may not shell out cannot run `rspec` and read the terminal;
      # it asks the port and reads the answer, and if the answer is a bare
      # event name then the door leads nowhere and it needs a shell after all.
      #
      # Both endings come back the same way, and the status stays 0 for both.
      # A refusal here is not a misuse — `IssueStillOpen` and `SuiteFailed`
      # are answers the caller asked for, correctly delivered. Exit 1 is for
      # "you typed something wrong", and conflating the two would have a
      # scripted agent treat a healthy no as a broken call.
      #
      # @param handle [Runtime::Dispatcher::Result, Runtime::RemoteDispatcher::Result] the
      #   dispatch result, which for a port operation has a nil `state`
      # @return [Hash{Symbol => Object}] `:id`, the result's id or else the first event's
      #   (nil when there is neither), and `:events`, an Array of `{ name:, payload: }`
      #   Hashes with each payload materialized to plain data
      def answered(handle)
        # The ID comes off the event, because a port operation hydrates no
        # instance and the handle's own `id` is nil by design. The event knows
        # which record was asked about — it was stamped with it — and printing
        # `null` beside a payload that plainly says `SW-TOOL` would read as a
        # bug in something.
        { id:     handle.id || handle.events.first&.id,
          events: handle.events.map do |event|
            { name: event.name, payload: JsonDoor.materialize(event.payload) }
          end }
      end

      # Words the answer to a verb or question that does not exist, suggesting up to five
      # names that start the same way.
      #
      # A near miss is worth more than a list. Somebody who typed
      # `bug.discovr` wants one line, not eighty-seven of them.
      #
      # Ranked by shared prefix, not by substring. Substring matching finds
      # nothing for the commonest typo of all — a dropped
      # letter, `order.create_piza`, which is a substring of nothing. Prefix
      # length survives an error anywhere after it, which is where errors are.
      #
      # @param cli [Hash{Symbol => Object}] the `Projector::CliProjector` projection; read
      #   for `cli[:names]`, the alias maps under `:command` and `:question`
      # @param name [String] what the caller typed
      # @param asking [Boolean] whether it was typed after `ask`, which picks the question
      #   names and the wording
      # @param program [String] how the caller was invoked, echoed in the closing hint
      # @return [String] a multi-line message; candidates must share a prefix of at least
      #   half of `name`'s length, and never fewer than three characters
      def unknown(cli, name, asking, program)
        # **Both spellings are candidates**. A caller who typed the qualified
        # form with a typo — `order.create_piza` — shares no prefix with the
        # short name `create_pizza`, so pooling only one of them suggests
        # nothing for half the mistakes anybody makes.
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

      # Counts how many leading characters two names have in common.
      #
      # @param one [String] a candidate name
      # @param other [String] the name to compare it with
      # @return [Integer] the length of the common prefix, from 0 up to the shorter
      #   name's length
      def shared_prefix(one, other)
        length = [one.length, other.length].min
        (0...length).find { |index| one[index] != other[index] } || length
      end
    end
  end
end
