require "json"
require "fileutils"
require "time"
require_relative "facade/command_request"
require_relative "facade/json_door"
require_relative "naming"
require_relative "projector"
require_relative "runtime/errors"

module Hecks
  # THE BUS, NOT A DOOR — `docs/hecks-survey-what-we-wish-we-had.md` and
  # `docs/future-features.md` both name the sibling project's own
  # "Storehouse" the single highest-priority gap this repo had: "no
  # per-command tool... the bluebook IS the contract, the [door] just
  # projects it." This module IS that bus, borrowing its name too — the
  # dispatch/query/state/... surface below is a pure function of a
  # `Runtime::Dispatcher` plus plain Ruby arguments, no IO, no protocol
  # awareness. `bin/hecks_mcp_door` is ONE projection of it — MCP over
  # stdio — not the whole thing; a plain CLI door, an HTTP door, a second
  # transport of any shape, would sit beside it on the exact same bus,
  # sharing the same audit log and caller-identity handling, without
  # ever needing to speak MCP. (This module used to BE named `McpDoor`
  # and live under `Facade` — that conflated the bus with its one built
  # transport; this file is the rename, not a rewrite.)
  #
  #   catalog  — what aggregates a domain declares, and what each can do
  #   describe — one aggregate's full command/query/refusal contract
  #   validate — is this domain's wiring sound (deep: also model-checks it)
  #   domains  — every domain directory under a root, discovered not typed
  #   dispatch — issue a command (dry_run: preview, steps: batch)
  #   query    — ask a question
  #   state    — read what is actually stored, no verb involved
  #   events   — what HAPPENED, with payloads, to one record — not just its
  #              current state; events THIS BUS witnessed, sourced from
  #              its own audit log, not a full event-sourcing replay
  #   history  — the full append-only journal, not just current state
  #   behaviors — run a domain's hand-curated `.behaviors` examples
  #   follow   — tail this bus's own dispatch/query/state audit log
  #
  # `dispatch`/`query`/`state` EACH TAKE A `summary` — the survey's "every
  # audit row carries human intent for free" — and `dispatch`/`query`
  # additionally take an optional `source:` (`SOURCE_TAGS`, the survey's
  # `SourceTag`: who is calling) AND an optional `role:`/`actor_id:` —
  # a real caller identity, bound for the call's duration via `Hecks.
  # as_caller`, the one thing that makes a `role`-gated command's
  # authorization actually checkable through this bus rather than merely
  # documented by `describe`. Every call through those three, plus a dry
  # run, is appended to a per-domain JSONL audit log (`record!`) `follow`
  # tails back. `catalog`/`describe`/`validate`/`domains`/`history`/
  # `behaviors`/`events` need neither — they change nothing and commit
  # nothing to any log.
  #
  # A CALLER HANDS IN AN ALREADY-BOOTED `runtime`, the same division of
  # labor `Facade::CliRunner` already keeps against `bin/run`: booting a
  # domain from a path is IO the calling `bin/` script owns, this stays a
  # pure function of a `Runtime::Dispatcher` plus plain Ruby arguments —
  # no different from `CliRunner.call(runtime:, argv:)` itself.
  # `validate` and `domains` are the two exceptions: `validate`'s whole
  # job is to attempt the boot and report whether it survived, so it
  # takes the domain PATH instead and boots it; `domains` has no
  # domain to be handed one of yet, that's what it's answering.
  #
  # NO NEW VOCABULARY otherwise. Every method here composes doors that
  # already exist — `Projector.call(:cli, ...)` for verb/question alias
  # resolution (the identical table `CliRunner` itself resolves against),
  # `Projector.call(:docs, ...)` for `describe`, `Facade::JsonDoor` for
  # the JSON↔Runtime::Value boundary, `Registry#repository` for `state`/
  # `history`, `Registry#verify!` (run by every boot) for `validate`,
  # `Bluebook::ModelCheck` for `validate(deep: true)`, `Hecks::Behaviors`
  # for `behaviors`, `Adapters::Folder#domain?` for `domains`,
  # `Dispatcher#dry_run?` for `dispatch(dry_run: true)`. A second copy of
  # any of these here would be the exact duplication `Facade::JsonDoor`'s
  # own header already warns against.
  module Storehouse
    module_function

    # THE SAME CLOSED SET `docs/hecks-survey-what-we-wish-we-had.md`'s
    # `SourceTag` names — WHO dispatched, not WHAT. Optional: a caller
    # that omits it gets `source: nil` recorded, honestly, rather than a
    # guessed default.
    SOURCE_TAGS = %w[process-manager operator hook sidequest-agent cascade daemon].freeze

    # THE BUS'S OWN AUDIT TRAIL — a JSONL file per domain, one line per
    # `dispatch`/`query`/`state`/dry-run call, `follow` tails it back.
    # `tmp/`, not the domain's own directory: this is the BUS's record
    # of what was asked of it, not part of the domain's own persisted
    # state, and `tmp/` is already gitignored for exactly this kind of
    # local, disposable-but-useful-while-it-lasts file.
    LOG_ROOT = File.expand_path("../../tmp/storehouse", __dir__)

    # ── shared resolution helpers ────────────────────────────────────

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

    def valid_source!(source)
      return if source.nil? || SOURCE_TAGS.include?(source.to_s)

      raise Runtime::TypeMismatch, "source: #{source.inspect} is not one of #{SOURCE_TAGS.join(', ')}"
    end

    # `actor_id` NAMES WHO, `role` NAMES WHAT THEY HOLD — `Hecks.
    # as_caller` requires the latter always, the former is additive
    # (`Runtime::Caller::Current`'s own shape). An `actor_id` with no
    # `role` would silently do nothing rather than bind a real caller,
    # which is worse than refusing: a caller who thinks they've
    # identified themselves and haven't deserves to be told.
    def valid_caller!(role, actor_id)
      return unless actor_id && role.nil?

      raise Runtime::TypeMismatch, "actor_id: requires role: too — a caller names WHO through WHICH role they hold"
    end

    # BOUND FOR THE DURATION OF ONE CALL, THEN GONE — `Hecks.as_caller`
    # is itself a `Thread.current`-scoped `ensure`-guarded block, so
    # nothing here needs its own cleanup. `role: nil` (the default,
    # every caller before this) yields unbound, exactly as before:
    # `CommandRules::Authorization#refuse_role_mismatch` is OPT-IN on
    # both sides — no caller bound, no role declared, both unchecked.
    # Query authorization runs on a wholly separate mechanism
    # (`authorize policy, tenant: :field`, checked against an explicit
    # `tenant:` argument — see `Runtime::TenantScope`), so binding a
    # caller around a query has no effect on it TODAY; it is still
    # accepted here, for symmetry and for the audit log, against the
    # day a read model does check `Caller.current`.
    def with_caller(role, actor_id, &block)
      return block.call if role.nil?

      Hecks.as_caller(role: role, actor_id: actor_id, &block)
    end

    # `dry_run?` (Runtime::Dispatcher) understands only the OLD flat
    # legacy args shape — no to:/with: envelope, `route:` never passed
    # (its own header explains why: built directly against
    # CommandInterpreter/EntityInterpreter's pre-envelope contract,
    # never updated because nothing else needed it to be — a real
    # record of history, not a defect this bus should paper over
    # silently). `Facade::CommandRequest`/`spec[:legacy_receiver]`
    # already know how to NAME that same flat shape for every receiver
    # kind (a bare id under one string key for :aggregate, a
    # {aggregate:, entity:} pair of keys for :entity) — this is the one
    # door back INTO it.
    def flatten_legacy(envelope, receiver, legacy_receiver)
      facts = envelope[:with] || {}
      return facts unless envelope.key?(:to)

      route = envelope[:to]
      case receiver
      when :aggregate then facts.merge(legacy_receiver.to_sym => route)
      when :entity
        facts.merge(legacy_receiver.fetch(:aggregate).to_sym => route[:aggregate],
                    legacy_receiver.fetch(:entity).to_sym    => route[:entity])
      else facts
      end
    end

    # ── the audit log `follow` reads back ───────────────────────────────

    def log_path(domain_name)
      File.join(LOG_ROOT, "#{domain_name.to_s.gsub(/[^A-Za-z0-9_-]/, '_')}.jsonl")
    end

    # NEVER FAILS A REAL CALL BECAUSE ITS OWN AUDIT LOG COULDN'T BE
    # WRITTEN — a full disk or a permissions problem is a `follow`
    # feature going dark, not a reason to refuse the dispatch/query/
    # state call that was actually asked for.
    def record!(domain_name, tool:, summary:, source:, outcome:, verb: nil, role: nil, actor_id: nil)
      return unless domain_name

      entry = { time: Time.now.utc.iso8601, tool: tool, verb: verb, summary: summary, source: source,
                role: role, actor_id: actor_id,
                ok: outcome[:ok], id: outcome[:id], error: outcome[:error], events: outcome[:events] }.compact
      FileUtils.mkdir_p(LOG_ROOT)
      File.open(log_path(domain_name), "a") { |f| f.puts(JSON.generate(entry)) }
    rescue StandardError
      nil
    end

    # ── the three that drive it ────────────────────────────────────────

    # `dry_run: true` ANSWERS A DIFFERENT QUESTION than a real dispatch
    # does — "would this succeed", not "here is what happened" — so a
    # domain refusal is the legitimate, complete ANSWER (`ok: true,
    # would_succeed: false`), not a failed call. A malformed request
    # (unknown command, a bad args shape) is still a failed call
    # (`ok: false`) either way — it never reached the domain to be asked.
    def dispatch(runtime:, command:, summary:, args: {}, source: nil, dry_run: false, role: nil, actor_id: nil)
      bluebook = bluebook_for(runtime)
      tool     = dry_run ? "dry_run" : "dispatch"
      outcome  = perform_dispatch(runtime, bluebook, command, summary, args, source, dry_run, role, actor_id)

      record!(bluebook.name, tool: tool, verb: outcome[:verb], summary: summary, source: source,
              outcome: outcome, role: role, actor_id: actor_id)
      outcome.except(:verb)
    rescue *refusal_classes => e
      outcome = refused(e, summary: summary)
      record!(bluebook&.name, tool: tool, summary: summary, source: source, outcome: outcome,
              role: role, actor_id: actor_id)
      outcome
    end

    def perform_dispatch(runtime, bluebook, command, summary, args, source, dry_run, role, actor_id)
      require_summary!(summary)
      valid_source!(source)
      valid_caller!(role, actor_id)
      cli      = Projector.call(:cli, bluebook: bluebook, options: { program: "mcp" })
      spec     = resolve!(cli, command, asking: false)
      envelope = Facade::CommandRequest.normalize(Facade::JsonDoor.deep_symbolize(args),
                                                  receiver:        spec[:receiver],
                                                  legacy_receiver: spec[:legacy_receiver])

      result = with_caller(role, actor_id) do
        dry_run ? dry_run_outcome(runtime, spec, envelope, summary: summary) : real_dispatch(runtime, spec, envelope, summary)
      end
      result.merge(verb: spec[:verb])
    end

    def real_dispatch(runtime, spec, envelope, summary)
      result = runtime.dispatch(spec[:verb], **envelope)
      ok(summary: summary,
         id:      result.id,
         state:   result.state.nil? ? nil : Facade::JsonDoor.materialize(result.state),
         events:  result.events.map { |event| { name: event.name, payload: Facade::JsonDoor.materialize(event.payload) } })
    end

    def dry_run_outcome(runtime, spec, envelope, summary:)
      flat = flatten_legacy(envelope, spec[:receiver], spec[:legacy_receiver])
      runtime.dry_run?(spec[:verb], **flat)
      ok(summary: summary, would_succeed: true)
    rescue Runtime::WiringError, *Runtime::DOMAIN_REFUSALS => e
      ok(summary: summary, would_succeed: false, error: e.message)
    end

    # ONE CALL, MANY STEPS — the survey's own `bin/run <domain> script`
    # shape, so an agent issuing a known SEQUENCE of commands (open an
    # account, then fund it) pays one round trip instead of N. Every step
    # goes through `dispatch` itself — same resolution, same audit log
    # line per step, same summary/source stamped on all of them since
    # the batch is what the caller is declaring intent about, not each
    # individual step. Runs every step regardless of an earlier one
    # refusing — a later step naming a record an earlier step never
    # created will refuse honestly on its own account, which is more
    # informative than silently dropping the rest of the batch.
    def dispatch_batch(runtime:, steps:, summary:, source: nil, role: nil, actor_id: nil)
      require_summary!(summary)
      results = Array(steps).map do |raw|
        step = Facade::JsonDoor.deep_symbolize(raw)
        dispatch(runtime: runtime, command: step[:command], args: step[:args] || {},
                 summary: summary, source: source, role: role, actor_id: actor_id)
      end
      { ok: results.all? { |r| r[:ok] }, summary: summary, results: results }
    rescue *refusal_classes => e
      refused(e, summary: summary)
    end

    def query(runtime:, question:, summary:, args: {}, source: nil, role: nil, actor_id: nil)
      bluebook = bluebook_for(runtime)
      outcome  = perform_query(bluebook, runtime, question, summary, args, source, role, actor_id)

      record!(bluebook.name, tool: "query", verb: outcome[:verb], summary: summary, source: source,
              outcome: outcome, role: role, actor_id: actor_id)
      outcome.except(:verb)
    rescue *refusal_classes => e
      outcome = refused(e, summary: summary)
      record!(bluebook&.name, tool: "query", summary: summary, source: source, outcome: outcome,
              role: role, actor_id: actor_id)
      outcome
    end

    def perform_query(bluebook, runtime, question, summary, args, source, role, actor_id)
      require_summary!(summary)
      valid_source!(source)
      valid_caller!(role, actor_id)
      cli  = Projector.call(:cli, bluebook: bluebook, options: { program: "mcp" })
      spec = resolve!(cli, question, asking: true)
      rows = with_caller(role, actor_id) { runtime.query(spec[:verb], **Facade::JsonDoor.deep_symbolize(args)) }

      ok(summary: summary, rows: rows.map { |row| Facade::JsonDoor.materialize(row) }).merge(verb: spec[:verb])
    end

    # WHAT IS ACTUALLY STORED — no verb, no interpretation, the repository
    # itself. `id:` given answers one record (`NotFound` when it names
    # nothing); omitted answers every record the aggregate currently
    # holds. This is the difference `query` can't cover: a query answers a
    # DECLARED question, and an aggregate that never declared "list
    # everything" has no query this could reuse.
    def state(runtime:, aggregate:, summary:, id: nil, source: nil)
      bluebook = bluebook_for(runtime)
      outcome  = perform_state(runtime, bluebook, aggregate, summary, id)

      record!(bluebook.name, tool: "state", summary: summary, source: source, outcome: outcome)
      outcome
    rescue *refusal_classes => e
      outcome = refused(e, summary: summary)
      record!(bluebook&.name, tool: "state", summary: summary, source: source, outcome: outcome)
      outcome
    end

    def perform_state(runtime, bluebook, aggregate, summary, id)
      require_summary!(summary)
      ir         = aggregate_ir!(bluebook, aggregate)
      repository = runtime.registry.repository(bluebook.name, ir)

      if id
        instance = repository.find(id) or
          raise Runtime::NotFound, "no #{ir.hecks_name} found for id #{id.inspect}"
        ok(summary: summary, record: Facade::JsonDoor.materialize(instance.to_h))
      else
        records = repository.all.map { |instance| Facade::JsonDoor.materialize(instance.to_h) }
        ok(summary: summary, count: records.length, records: records)
      end
    end

    # ── the four zoom levels ─────────────────────────────────────────

    # ZOOM LEVEL ZERO — every domain directory a root actually holds,
    # discovered rather than typed from memory. Every other tool takes
    # `domain:` as a directory it assumes the caller already knows; this
    # is how a caller who doesn't finds out. `Adapters::Folder#domain?`
    # is the same predicate `domain_root`/`nearest_domain` already walk
    # up directories checking — a bare `.hecksagon` or one under
    # `bluebook/`, the two real shapes this corpus uses.
    def domains(under: "examples")
      root = File.expand_path(under)
      return ok(under: under, domains: []) unless Dir.exist?(root)

      folder = Adapters::Folder.new
      found  = Dir.children(root).sort.select { |name| folder.domain?(File.join(root, name)) }

      ok(under: under, domains: found.map { |name| File.join(under, name) })
    end

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
    # `deep: true` GOES PAST WIRING INTO LOGIC — `Bluebook::ModelCheck`,
    # the lightweight-formal-methods leg (dead lifecycle transitions, a
    # saga state no handler chain reaches, a dispatch to nowhere). Opt-in
    # and separate from the base check on purpose: a wiring defect is
    # "this cannot run at all", a model-check finding is "this runs, but
    # part of it can never fire" — two different questions, and the
    # first is far cheaper to ask on every boot.
    #
    # ANY BOOT FAILURE ANSWERS THE QUESTION, not only `WiringError` — a
    # domain path with no `.hecksagon`, a malformed bluebook, is just as
    # much "not valid" as a real wiring mismatch, and this tool exists
    # precisely so none of those ever cross a projection of this bus as
    # a crash.
    def validate(domain:, deep: false)
      runtime = Hecks.boot(domain, install_facade: false)
      result  = { ok: true, domain: domain, valid: true }

      if deep
        require_relative "bluebook/model_check"
        findings = runtime.registry.bluebooks.values.flat_map { |bluebook| Bluebook::ModelCheck.call(bluebook) }
        result[:findings] = findings.map { |f| { kind: f.kind, severity: f.severity, subject: f.subject, message: f.message } }
      end

      result
    rescue StandardError => e
      { ok: false, domain: domain, valid: false, error: "#{e.class}: #{e.message}" }
    end

    # ── beyond the zoom levels ──────────────────────────────────────────

    # THE FULL WRITE HISTORY, not just the current head — `bin/history`'s
    # own logic, unchanged: an append-only-backed aggregate's `entries`,
    # every operation that ever touched it. An aggregate bound to a
    # non-append-only adapter (Memory, Postgres proper) answers an empty
    # list honestly rather than pretending to a history it never kept.
    def history(runtime:)
      bluebook = bluebook_for(runtime)
      entries  = bluebook.aggregates.each_with_object({}) do |aggregate, all|
        repository = runtime.registry.repository(bluebook.name, aggregate)
        all[aggregate.storage_name] = journal_entries(repository)
      end

      ok(domain: bluebook.name, history: entries)
    rescue *refusal_classes => e
      refused(e)
    end

    def journal_entries(repository)
      return [] unless repository.is_a?(Ports::Persistence::AppendOnly)

      repository.entries.map { |entry| { operation: entry.operation, id: entry.id, state: Facade::JsonDoor.materialize(entry.state) } }
    end

    # `.behaviors` FILES, RUN AND REPORTED — hand-curated examples of how
    # to use a domain, in domain vocabulary (`docs/guides/behaviors.md`),
    # the survey's own "honest-refusal", generated-example-suite items.
    # `Hecks::Behaviors` boots each test fresh through `Hecks.boot_files`
    # itself — `target:` names a `.behaviors` file OR a directory to
    # sweep, never a `runtime:`, the one other method here besides
    # `validate` that takes a path instead.
    def behaviors(target:)
      require_relative "behaviors"
      raise Runtime::NotFound, "no such file or directory: #{target.inspect}" unless target && File.exist?(target)

      if File.directory?(target)
        sweep = Hecks::Behaviors.run_all(target)
        ok(target: target, files: sweep.files.map { |file| behaviors_file(file) }, counts: sweep.summary)
      else
        result = Hecks::Behaviors.run(target)
        ok(target: target, files: [behaviors_file(result)], counts: Hecks::Behaviors.summarize([result]))
      end
    rescue *refusal_classes => e
      refused(e)
    end

    def behaviors_file(result)
      { path:        result.path,
        parse_error: result.parse_error,
        runs:        Array(result.runs).map { |run| { description: run.description, status: run.status, message: run.message } } }
    end

    # A LIVE TAIL WITHOUT A LIVE PROCESS — `bin/hecks_mcp_door` (its
    # transport of MCP-over-stdio) answers one request at a time, no push
    # channel to a client that only ever asks. This is the honest version
    # of the survey's `storehouse follow` for that shape: not a
    # subscription, a durable JSONL log every `dispatch`/`query`/`state`/
    # dry-run call appends to (`record!`), tailed back here. Still real,
    # still cross-process — the log outlives any one door's own process —
    # just pull instead of push.
    def follow(runtime:, limit: 20)
      bluebook = bluebook_for(runtime)
      entries  = log_lines(bluebook.name).last([limit.to_i, 1].max)

      ok(domain: bluebook.name, entries: entries)
    rescue *refusal_classes => e
      refused(e)
    end

    def log_lines(domain_name)
      path = log_path(domain_name)
      return [] unless File.exist?(path)

      File.readlines(path).map { |line| JSON.parse(line, symbolize_names: true) }
    end

    # WHAT ACTUALLY HAPPENED, with payloads — distinct from `state`
    # (what's stored NOW) and `history` (append-only operation
    # SNAPSHOTS, no payload). NOT a domain-wide event-sourcing replay:
    # "one boot per call" means `runtime.events` is always empty except
    # during the very call that populated it, discarded the moment that
    # call returns — there is no cross-call in-memory log to read here.
    # So this reads the SAME durable audit log `follow` already tails
    # (`record!` now stamps a successful dispatch's own announced
    # events onto its log line), reshaped: `follow` answers "what was
    # CALLED, in order, across every tool"; this answers "what HAPPENED
    # to one aggregate/record" — events THIS BUS witnessed, which is
    # every real dispatch ever routed through it, but no more than that.
    # `aggregate:` narrows to one aggregate; `id:` (requires
    # `aggregate:` — an id alone is not unique across aggregates)
    # narrows to one record's own events.
    def events(runtime:, aggregate: nil, id: nil, limit: nil)
      raise Runtime::TypeMismatch, "id: requires aggregate: too — an id alone is not unique across aggregates" if id && !aggregate

      bluebook = bluebook_for(runtime)
      fqn      = aggregate ? "#{bluebook.name}::#{aggregate_ir!(bluebook, aggregate).hecks_name}" : nil

      found = log_lines(bluebook.name).filter_map do |entry|
        next unless entry[:tool] == "dispatch" && entry[:ok] && entry[:events]
        next if fqn && !entry[:verb].to_s.start_with?("#{fqn}.")
        next if id && entry[:id] != id

        entry[:events].map { |event| event.merge(time: entry[:time], verb: entry[:verb], id: entry[:id]) }
      end.flatten(1)

      found = found.last(limit.to_i) if limit

      ok(domain: bluebook.name, events: found)
    rescue *refusal_classes => e
      refused(e)
    end

    # ── shared shape ────────────────────────────────────────────────────

    # `Runtime::WiringError` BELONGS HERE TOO, alongside the true domain
    # refusals — not because it IS one (it's a structural defect, not a
    # rule the caller broke), but because "this domain isn't wired to
    # answer what you're asking" (a `role:`+`actor_id:` caller reaching
    # an authorization port nothing implements, a dry run against a
    # port verb) is exactly the shape this bus promises never crashes
    # through it. `dry_run_outcome` already treats it this way locally;
    # this makes every OTHER caller of `refusal_classes` do the same.
    def refusal_classes = [Runtime::NotFound, Runtime::TypeMismatch, Runtime::WiringError, *Runtime::DOMAIN_REFUSALS]

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
