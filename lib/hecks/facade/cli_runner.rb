require "json"
require_relative "cli_door"
require_relative "command_request"
require_relative "json_door"
require_relative "../projector"
require_relative "../ports/clock"

module Hecks
  module Facade
    # THE RUNNER BEHIND A PROJECTED CLI.
    #
    # `Projector::CliProjector` answers what a domain's command line LOOKS
    # like; this is the twenty lines that parse against it and dispatch. It
    # lives in `lib/` rather than in a `bin/` because more than one front door
    # wants it — `bin/run` for whichever domain you are standing in, `bin/qc`
    # pinned to the QA ledger — and a second copy of the parse-and-dispatch
    # would be the exact duplication the projection exists to avoid.
    #
    # NO IO. It answers `[text, status]` and never prints or exits, so a spec
    # can call it without capturing streams or trapping SystemExit. The `bin/`
    # scripts do the printing, the same division `Router` and `JsonDoor`
    # already keep against HTTP.
    module CliRunner
      module_function

      # `[text, status]` — status 0 answered, 1 refused or misused.
      def call(runtime:, argv:, program: "bin/run")
        bluebook = runtime.registry.bluebooks.values.first
        cli      = Projector.call(:cli, bluebook: bluebook, options: { program: program })

        name = argv.first
        return [cli[:usage], 0] if name.nil? || %w[--help -h help].include?(name)

        # `ask` PUTS A QUESTION IN ITS OWN NAMESPACE — a chapter may declare a
        # command and a query of one name, and banking does.
        asking = name == "ask"
        argv   = argv[1..] if asking
        name   = argv.first
        return [cli[:usage], 1] if name.nil?

        # RESOLVED THROUGH THE ALIAS MAP, so `pizzas create_pizza` and
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

      def dispatch(runtime, spec, name, rest, program, asking)
        args = stamp_time(runtime, spec, CliDoor.arguments(spec, rest))

        if spec[:kind] == :query
          rows = runtime.query(spec[:verb], **args)
          return [JSON.pretty_generate(rows.map { |row| JsonDoor.materialize(row) }), 0]
        end

        # THE ANSWER IS SCOPED TO WHAT WAS ASKED. `bin/run`'s step-list form
        # reports the whole store because a corpus run is judged on all of it;
        # somebody who issued one verb wants that verb's outcome, and against a
        # Postgres-backed domain the full dump is every record there has been.
        request = CommandRequest.normalize(args, receiver:        spec[:receiver],
                                                 legacy_receiver: spec[:legacy_receiver])
        handle = runtime.dispatch(spec[:verb], **request)
        return [JSON.pretty_generate(answered(handle)), 0] if handle.state.nil?

        [JSON.pretty_generate(id:     handle.id,
                              state:  JsonDoor.materialize(handle.state),
                              events: handle.events.map(&:name)), 0]
      rescue Runtime::NotFound, Runtime::TypeMismatch => e
        # A BAD ARGUMENT AND A MISSING RECORD BOTH LAND HERE, and both want the
        # same next step: read what the verb actually takes.
        ["#{e.message}\n\n  #{program} #{asking ? 'ask ' : ''}#{name} --help", 1]
      rescue *Runtime::DOMAIN_REFUSALS => e
        # THE REFUSAL IS THE PRODUCT — the chapter's own sentence, verbatim.
        [e.message, 1]
      end

      # THE CLOCK, FILLED IN AT THE DOOR.
      #
      # A staleness rule needs the time, and the sublanguage cannot ask for it
      # — a `given` that read the clock would judge the same record differently
      # on two runs, and every replay, audit and fuzz oracle here assumes it
      # does not. So `now` stays an ARGUMENT the predicate merely reads, and
      # the question becomes who types it. Before this, the caller did:
      #
      #   qa/quality_control target.claim id=QC held_by.value=me \
      #     now.value=$(date +%s) window.value=900
      #
      # which is a shell incantation in front of every claim, and one an agent
      # gets wrong by pasting a stale number.
      #
      # AT THE DOOR, NOT IN THE RUNTIME, and the distinction is load-bearing.
      # `Ports::IdentityGeneration` reasons the same question through for a
      # minted uuid and lands on "the value is baked into the caller's args at
      # the first live dispatch". A clock consulted INSIDE the interpreter
      # would not have that property — a recorded corpus step replayed
      # tomorrow would quietly get tomorrow's time, and the fuzzer's oracle and
      # the adapter-agreement gate both compare runs of exactly that shape. Here
      # it fills only what a person or an agent is typing, and `runtime.dispatch`
      # is left alone.
      #
      # AN EXPLICIT VALUE ALWAYS WINS, so a spec or a caller reproducing a
      # moment says so and is believed. This only supplies what was omitted.
      #
      # BY NAME, WHICH IS THE ONE UNCOMFORTABLE PART. `now` is a plausible
      # domain word and nothing declares that it means the clock. It is
      # tolerable because this is a convenience layer rather than semantics —
      # the verb's own help says the argument exists, dispatch is unchanged,
      # and passing it explicitly is always available. The honest version is a
      # declaration in the chapter (`attribute :now, Instant, from: :clock`),
      # which is a language change: DSL, IR, the self-hosted grammar and its
      # goldens. Worth doing; not worth smuggling in here.
      def stamp_time(runtime, spec, args)
        return args unless spec[:arguments].any? { |argument| argument[:path].start_with?("now.") }
        return args if args.key?(:now)

        args.merge(now: { value: Ports::Clock.now(runtime.registry) })
      end

      # A PORT OPERATION HAS NO STATE, AND ITS PAYLOAD IS THE ENTIRE POINT.
      #
      # A command answers with the record it changed, so naming the events is
      # enough — the interesting part is in `state`. A port operation changes
      # no record: it asked something outside and came back with what was
      # said, and that lives ONLY in the event payload. Reporting names alone
      # would print `SpecsCompleted` and drop the spec output on the floor.
      #
      # This is what makes a projected CLI usable as somebody's only door. An
      # agent that may not shell out cannot run `rspec` and read the terminal;
      # it asks the port and reads the answer, and if the answer is a bare
      # event name then the door leads nowhere and it needs a shell after all.
      #
      # BOTH ENDINGS COME BACK THE SAME WAY, and the status stays 0 for both.
      # A refusal here is not a misuse — `IssueStillOpen` and `SuiteFailed`
      # are answers the caller asked for, correctly delivered. Exit 1 is for
      # "you typed something wrong", and conflating the two would have a
      # scripted agent treat a healthy no as a broken call.
      def answered(handle)
        # THE ID COMES OFF THE EVENT, because a port operation hydrates no
        # instance and the handle's own `id` is nil by design. The event knows
        # which record was asked about — it was stamped with it — and printing
        # `null` beside a payload that plainly says `SW-TOOL` would read as a
        # bug in something.
        { id:     handle.id || handle.events.first&.id,
          events: handle.events.map do |event|
            { name: event.name, payload: JsonDoor.materialize(event.payload) }
          end }
      end

      # A NEAR MISS IS WORTH MORE THAN A LIST. Somebody who typed
      # `bug.discovr` wants one line, not eighty-seven of them.
      #
      # RANKED BY SHARED PREFIX, not by substring. Substring was the first
      # attempt and it finds nothing for the commonest typo of all — a dropped
      # letter, `order.create_piza`, which is a substring of nothing. Prefix
      # length survives an error anywhere after it, which is where errors are.
      def unknown(cli, name, asking, program)
        # BOTH SPELLINGS ARE CANDIDATES. A caller who typed the qualified
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
        lines += ["", "  #{program}#{asking ? ' ask' : ''}   for the full list"]
        lines.join("\n")
      end

      def shared_prefix(one, other)
        length = [one.length, other.length].min
        (0...length).find { |index| one[index] != other[index] } || length
      end
    end
  end
end
