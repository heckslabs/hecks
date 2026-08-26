require_relative "command_request"
require_relative "json_door"
require_relative "../naming"
require_relative "../projector"
require_relative "../runtime/errors"

module Hecks
  module Facade
    # THE UNIVERSAL MCP DOOR — one door onto every domain, not one tool per
    # verb. `docs/hecks-survey-what-we-wish-we-had.md` and
    # `docs/future-features.md` both name this the single highest-priority
    # gap against the sibling project's ten-tool Storehouse MCP: "no
    # per-command tool... the bluebook IS the contract, the MCP layer just
    # projects it." This is that projection, at six tools instead of ten —
    # `macrophage_check`/`behaviors`/`conceive_behaviors` are that project's
    # own governed-door and behaviour-generation machinery, which this repo
    # has no equivalent of yet.
    #
    # THREE ZOOM LEVELS, the survey's own framing:
    #   catalog  — what aggregates a domain declares, and what each can do
    #   describe — one aggregate's full command/query/refusal contract
    #   validate — is this domain's wiring sound at all
    # …and three ways to actually DRIVE it:
    #   dispatch — issue a command
    #   query    — ask a question
    #   state    — read what is actually stored, no verb involved
    #
    # `dispatch`/`query`/`state` EACH REQUIRE A `summary` — the survey's
    # "every audit row carries human intent for free". `catalog`/`describe`/
    # `validate` do not: they change nothing and commit nothing to any log,
    # so there is no audit row for a summary to attach to.
    #
    # A CALLER HANDS IN AN ALREADY-BOOTED `runtime`, the same division of
    # labor `Facade::CliRunner` already keeps against `bin/run`: booting a
    # domain from a path is IO the calling `bin/` script owns, this stays a
    # pure function of a `Runtime::Dispatcher` plus plain Ruby arguments, no
    # different from `CliRunner.call(runtime:, argv:)` itself. `validate` is
    # the one exception — its whole job is to attempt the boot and report
    # whether it survived, so it takes the domain PATH instead and boots it.
    #
    # NO NEW VOCABULARY otherwise. Every method here composes doors that
    # already exist — `Projector.call(:cli, ...)` for verb/question alias
    # resolution (the identical table `CliRunner` itself resolves against),
    # `Projector.call(:docs, ...)` for `describe`, `JsonDoor` for the
    # JSON↔Runtime::Value boundary, `Registry#repository` for `state`,
    # `Registry#verify!` (run at boot by `Runtime::Loader.boot`) for
    # `validate`. A second copy of "how do I find a command by its short
    # name" here would be the exact duplication `JsonDoor`'s own header
    # already warns against.
    module McpDoor
      module_function

      # THE ONE BLUEBOOK A DOMAIN DIRECTORY BOOTS. Every `bin/*` script that
      # projects a whole-domain CLI or doc set makes this same assumption
      # (`Facade::CliRunner#call`'s own `bluebook = runtime.registry.
      # bluebooks.values.first`) — one `.hecksagon` names one chapter.
      def bluebook_for(runtime)
        runtime.registry.bluebooks.values.first or
          raise Runtime::NotFound, "this boot loaded no bluebook"
      end

      def aggregate_ir!(bluebook, name)
        bluebook.aggregate(name) or
          raise Runtime::NotFound, "#{bluebook.name} declares no aggregate named #{name.inspect} — " \
                                   "known: #{bluebook.aggregates.map(&:hecks_name).sort.join(', ')}"
      end

      # THE SAME ALIAS TABLE `CliRunner` RESOLVES A TYPED WORD AGAINST — a
      # short name when it's unambiguous, the qualified `Aggregate.Verb`
      # form always. Shared here so `dispatch` and `query` (and their error
      # messages) never drift from what a human typing `bin/run` sees.
      def resolve!(cli, name, asking:)
        pool = asking ? cli[:questions] : cli[:verbs]
        key  = cli[:names][asking ? :question : :command][name]
        spec = pool[key]
        return spec if spec

        known = cli[:names][asking ? :question : :command].keys.sort.join(", ")
        raise Runtime::NotFound, "no such #{asking ? 'query' : 'command'}: #{name.inspect} — known: #{known}"
      end

      def require_summary!(summary)
        return unless summary.nil? || summary.to_s.strip.empty?

        raise Runtime::TypeMismatch,
              "a one-line summary: is required on dispatch/query/state — it is what makes an audit row legible later"
      end

      # ── the three that drive it ────────────────────────────────────────

      def dispatch(runtime:, command:, summary:, args: {})
        require_summary!(summary)
        cli     = Projector.call(:cli, bluebook: bluebook_for(runtime), options: { program: "mcp" })
        spec    = resolve!(cli, command, asking: false)
        request = CommandRequest.normalize(JsonDoor.deep_symbolize(args),
                                           receiver:        spec[:receiver],
                                           legacy_receiver: spec[:legacy_receiver])
        result = runtime.dispatch(spec[:verb], **request)

        ok(summary: summary,
           id:      result.id,
           state:   result.state.nil? ? nil : JsonDoor.materialize(result.state),
           events:  result.events.map { |event| { name: event.name, payload: JsonDoor.materialize(event.payload) } })
      rescue *refusal_classes => e
        refused(e, summary: summary)
      end

      def query(runtime:, question:, summary:, args: {})
        require_summary!(summary)
        cli  = Projector.call(:cli, bluebook: bluebook_for(runtime), options: { program: "mcp" })
        spec = resolve!(cli, question, asking: true)
        rows = runtime.query(spec[:verb], **JsonDoor.deep_symbolize(args))

        ok(summary: summary, rows: rows.map { |row| JsonDoor.materialize(row) })
      rescue *refusal_classes => e
        refused(e, summary: summary)
      end

      # WHAT IS ACTUALLY STORED — no verb, no interpretation, the repository
      # itself. `id:` given answers one record (`NotFound` when it names
      # nothing); omitted answers every record the aggregate currently
      # holds. This is the difference `query` can't cover: a query answers a
      # DECLARED question, and an aggregate that never declared "list
      # everything" has no query this could reuse.
      def state(runtime:, aggregate:, summary:, id: nil)
        require_summary!(summary)
        bluebook   = bluebook_for(runtime)
        ir         = aggregate_ir!(bluebook, aggregate)
        repository = runtime.registry.repository(bluebook.name, ir)

        if id
          instance = repository.find(id) or
            raise Runtime::NotFound, "no #{ir.hecks_name} found for id #{id.inspect}"
          ok(summary: summary, record: JsonDoor.materialize(instance.to_h))
        else
          records = repository.all.map { |instance| JsonDoor.materialize(instance.to_h) }
          ok(summary: summary, count: records.length, records: records)
        end
      rescue *refusal_classes => e
        refused(e, summary: summary)
      end

      # ── the three zoom levels ───────────────────────────────────────────

      # ZOOM LEVEL ONE — every aggregate this domain declares, and every
      # command/query name each answers to, snake_cased exactly as
      # `dispatch`/`query` want it. Enough to pick a target; `describe` is
      # the next level down for what one of them actually takes.
      def catalog(runtime:)
        bluebook = bluebook_for(runtime)

        ok(domain:     bluebook.name,
           aggregates: bluebook.aggregates.map do |aggregate|
             { name:     aggregate.hecks_name,
               commands: aggregate.commands.map { |c| "#{Naming.snake(c.hecks_name)}!" }.sort,
               queries:  aggregate.queries.map { |q| Naming.snake(q.hecks_name) }.sort }
           end)
      rescue *refusal_classes => e
        refused(e)
      end

      # ZOOM LEVEL TWO — the exact same usage document a human gets from
      # `bin/docs <domain> [aggregate]` (`Projector::DocsProjector`, the
      # identical projection `Surface::AggregateDoor#docs` calls one door
      # over): every command's arguments, the states it may be issued
      # from, and every way it can refuse. `aggregate:` omitted answers the
      # whole chapter.
      def describe(runtime:, aggregate: nil)
        bluebook = bluebook_for(runtime)
        options  = aggregate ? { aggregate: aggregate_ir!(bluebook, aggregate).hecks_name } : {}

        ok(domain: bluebook.name, docs: Projector.call(:docs, bluebook: bluebook, options: options))
      rescue *refusal_classes => e
        refused(e)
      end

      # ZOOM LEVEL THREE — is the wiring sound at all: every bind names a
      # declared aggregate, every adapter satisfies the port it claims, the
      # default adapter is usable. `Registry#verify!` (`runtime/registry/
      # verification.rb`) is the one place this repo already answers that
      # question, and `Runtime::Loader.boot` already calls it as the last
      # step of every boot — so THIS is the one method here that boots for
      # itself rather than taking a `runtime:` already in hand, because a
      # runtime that successfully reached this line already answered the
      # question. Given a domain PATH, not a booted runtime, deliberately:
      # asking "is this valid" about a domain that failed to boot at all
      # has to be askable without a runtime to hand it.
      #
      # ANY BOOT FAILURE ANSWERS THE QUESTION, not only `WiringError` — a
      # domain path with no `.hecksagon`, a malformed bluebook, is just as
      # much "not valid" as a real wiring mismatch, and this tool exists
      # precisely so none of those ever cross the MCP boundary as a crash.
      def validate(domain:)
        Hecks.boot(domain, install_facade: false)
        { ok: true, domain: domain, valid: true }
      rescue StandardError => e
        { ok: false, domain: domain, valid: false, error: "#{e.class}: #{e.message}" }
      end

      # ── shared shape ────────────────────────────────────────────────────

      def refusal_classes = [Runtime::NotFound, Runtime::TypeMismatch, *Runtime::DOMAIN_REFUSALS]

      def ok(**fields) = { ok: true }.merge(fields)

      # AN HONEST REFUSAL, NOT A CRASH — the survey's own item #9: "an
      # explicit, structured refusal a caller can act on" rather than a
      # stack trace an agent has to parse to find the one line that
      # mattered. The domain's own refusal text travels verbatim
      # (`RefusalWording` already renders every one of these to be read),
      # this only wraps it consistently.
      def refused(error, summary: nil) = { ok: false, summary: summary, error: error.message }
    end
  end
end
