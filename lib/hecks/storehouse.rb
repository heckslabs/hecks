require "json"
require "fileutils"
require "time"
require_relative "facade/command_request"
require_relative "facade/json_door"
require_relative "naming"
require_relative "projector"
require_relative "runtime/errors"

module Hecks
  # **The bus, not a door** — `docs/hecks-survey-what-we-wish-we-had.md` and
  # `docs/future-features.md` both name the sibling project's own
  # "Storehouse" the single highest-priority gap this repo had: "no
  # per-command tool... the bluebook is the contract, the [door] just
  # projects it." This module is that bus, borrowing its name too — the
  # dispatch/query/state/... surface below is a pure function of a
  # `Runtime::Dispatcher` plus plain Ruby arguments, no IO, no protocol
  # awareness. `bin/hecks_mcp_door` is one projection of it — MCP over
  # stdio — not the whole thing; a plain CLI door, an HTTP door, a second
  # transport of any shape, would sit beside it on the exact same bus,
  # sharing the same audit log and caller-identity handling, without
  # ever needing to speak MCP. (This bus is deliberately not
  # `Facade::McpDoor` — folding it into `Facade` under that name would
  # conflate the bus with its one built transport.)
  #
  # ## The surface
  #
  #   catalog  — what aggregates a domain declares, and what each can do
  #   describe — one aggregate's full command/query/refusal contract
  #   validate — is this domain's wiring sound (deep: also model-checks it)
  #   domains  — every domain directory under a root, discovered not typed
  #   dispatch — issue a command (dry_run: preview, steps: batch)
  #   query    — ask a question
  #   state    — read what is actually stored, no verb involved
  #   events   — what happened, with payloads, to one record — not just its
  #              current state; events this bus witnessed, sourced from
  #              its own audit log, not a full event-sourcing replay
  #   history  — the full append-only journal, not just current state
  #   behaviors — run a domain's hand-curated `.behaviors` examples
  #   follow   — tail this bus's own dispatch/query/state audit log
  #
  # ## Auditing and caller identity
  #
  # `dispatch`/`query`/`state` each take a `summary` — the survey's "every
  # audit row carries human intent for free" — and `dispatch`/`query`
  # additionally take an optional `source:` (`SOURCE_TAGS`, the survey's
  # `SourceTag`: who is calling) and an optional `role:`/`actor_id:` —
  # a real caller identity, bound for the call's duration via `Hecks.
  # as_caller`, checked against a `role`-gated command's own declared
  # role (`CommandRules::Authorization`) rather than merely documented by
  # `describe`. `dispatch` requires it for any command that declares a
  # role — `require_caller_for_role_gated!` refuses an unbound dispatch
  # against one rather than silently running it unchecked; `query`'s own
  # authorization runs on a separate mechanism (`Runtime::TenantScope`)
  # that `role:` does not gate. This is self-asserted identity, not
  # authentication: the caller states its own `role`/`actor_id`, and this
  # bus checks it consistently once stated — see `bin/hecks_mcp_door`'s
  # header for what that does and does not guarantee. Every call through
  # those three, plus a dry run, is appended to a per-domain JSONL audit
  # log (`record!`) `follow` tails back — a record of what the caller
  # said it was, not independently verified identity. `catalog`/
  # `describe`/`validate`/`domains`/`history`/`behaviors`/`events` need
  # neither — they change nothing and commit nothing to any log.
  #
  # ## Booting is the caller's job
  #
  # A caller hands in an already-booted `runtime`, the same division of
  # labor `Facade::CliRunner` already keeps against `bin/run`: booting a
  # domain from a path is IO the calling `bin/` script owns, this stays a
  # pure function of a `Runtime::Dispatcher` plus plain Ruby arguments —
  # no different from `CliRunner.call(runtime:, argv:)` itself.
  # `validate` and `domains` are the two exceptions: `validate`'s whole
  # job is to attempt the boot and report whether it survived, so it
  # takes the domain path instead and boots it; `domains` has no
  # domain to be handed one of yet, that's what it's answering.
  #
  # ## Built from existing doors
  #
  # No new vocabulary otherwise. Every method here composes doors that
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

    # The same closed set `docs/hecks-survey-what-we-wish-we-had.md`'s
    # `SourceTag` names — who dispatched, not what. Optional: a caller
    # that omits it gets `source: nil` recorded, honestly, rather than a
    # guessed default.
    SOURCE_TAGS = %w[process-manager operator hook sidequest-agent cascade daemon].freeze

    # **The bus's own audit trail** — a JSONL file per domain, one line per
    # `dispatch`/`query`/`state`/dry-run call, `follow` tails it back.
    # `tmp/`, not the domain's own directory: this is the bus's record
    # of what was asked of it, not part of the domain's own persisted
    # state, and `tmp/` is already gitignored for exactly this kind of
    # local, disposable-but-useful-while-it-lasts file.
    LOG_ROOT = File.expand_path("../../tmp/storehouse", __dir__)

    # The root every `domain:`/`under:` must resolve under — the project
    # directory by default, `HECKS_STOREHOUSE_ROOT` to widen or move it.
    # `Hecks.boot` `Kernel.load`s the `.hecksagon`/`.bluebook`/`.world`
    # files a domain path resolves to, and those are Ruby, not a data
    # format — a caller-supplied path with no confinement at all is an
    # unmarked door out of "a narrower, checked surface" (the README's
    # own pitch for this bus) and into arbitrary code execution from any
    # path on disk. This is a boundary a local convention was standing
    # in for, not new behavior for a caller already confined to the
    # project tree.
    BOOT_ROOT = File.expand_path(ENV["HECKS_STOREHOUSE_ROOT"] || File.expand_path("../..", __dir__))

    # Resolves `path` against `BOOT_ROOT` and refuses one that escapes it.
    #
    # **Refused, not silently clamped** — a path outside `BOOT_ROOT` is either
    # an honest mistake (a relative path typed against the wrong cwd) or
    # the exact thing this check exists to catch, and both deserve the
    # same clear refusal rather than a silent rewrite to something the
    # caller didn't ask for.
    #
    # @param path [String, #to_s] the caller-supplied path to confine
    # @param label [String] the argument's own name, for the refusal message
    #   (e.g. `"domain"`, `"under"`)
    # @return [String] `path` resolved to an absolute path under `BOOT_ROOT`
    # @raise [Runtime::TypeMismatch] if the resolved path is outside `BOOT_ROOT`
    def confine!(path, label)
      resolved = File.expand_path(path.to_s, BOOT_ROOT)
      return resolved if resolved == BOOT_ROOT || resolved.start_with?("#{BOOT_ROOT}#{File::SEPARATOR}")

      raise Runtime::TypeMismatch,
            "#{label}: #{path.inspect} resolves outside #{BOOT_ROOT} — this bus only boots domains under its " \
            "own root (HECKS_STOREHOUSE_ROOT to widen it)"
    end

    # ── shared resolution helpers ────────────────────────────────────

    # The one bluebook a domain directory boots. Every `bin/*` script that
    # projects a whole-domain CLI or doc set makes this same assumption
    # (`Facade::CliRunner#call`'s own `bluebook = runtime.registry.
    # bluebooks.values.first`) — one `.hecksagon` names one chapter.
    # The one bluebook this runtime booted.
    #
    # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted runtime
    # @return [Bluebook::Chapter] the runtime's one loaded bluebook
    # @raise [Runtime::NotFound] if the runtime's boot loaded no bluebook
    def bluebook_for(runtime)
      runtime.registry.bluebooks.values.first or
        raise Runtime::NotFound, "this boot loaded no bluebook"
    end

    # Finds one aggregate by name on a bluebook, or refuses.
    #
    # @param bluebook [Bluebook::Chapter] the chapter to search
    # @param name [String, Symbol, #to_s] the aggregate's declared name
    # @return [Bluebook::Aggregate] the matching aggregate
    # @raise [Runtime::NotFound] if `bluebook` declares no aggregate named `name`
    def aggregate_ir!(bluebook, name)
      bluebook.aggregate(name) or
        raise Runtime::NotFound, "#{bluebook.name} declares no aggregate named #{name.inspect} — " \
                                 "known: #{bluebook.aggregates.map(&:hecks_name).sort.join(', ')}"
    end

    # The same alias table `CliRunner` resolves a typed word against — a
    # short name when it's unambiguous, the qualified `Aggregate.Verb`
    # form always. Shared here so `dispatch` and `query` (and their error
    # messages) never drift from what a human typing `bin/run` sees.
    #
    # @param cli [Hash{Symbol => Object}] a `Projector.call(:cli, ...)` result
    # @param name [String, Symbol, #to_s] the command or query name, as given by the caller
    # @param asking [Boolean] true to resolve a query (against `cli[:questions]`),
    #   false to resolve a command (against `cli[:verbs]`)
    # @return [Hash{Symbol => Object}] the resolved verb/question spec
    # @raise [Runtime::NotFound] if `name` matches no known command or query
    def resolve!(cli, name, asking:)
      pool = asking ? cli[:questions] : cli[:verbs]
      key  = cli[:names][asking ? :question : :command][name]
      spec = pool[key]
      return spec if spec

      known = cli[:names][asking ? :question : :command].keys.sort.join(", ")
      raise Runtime::NotFound, "no such #{asking ? 'query' : 'command'}: #{name.inspect} — known: #{known}"
    end

    # Refuses a call with no summary.
    #
    # @param summary [String, nil] the caller-supplied one-line summary
    # @return [void]
    # @raise [Runtime::TypeMismatch] if `summary` is nil or blank
    def require_summary!(summary)
      return unless summary.nil? || summary.to_s.strip.empty?

      raise Runtime::TypeMismatch,
            "a one-line summary: is required on dispatch/query/state — it is what makes an audit row legible later"
    end

    # Refuses a `source:` that is not one of `SOURCE_TAGS`.
    #
    # @param source [String, Symbol, nil] the caller-supplied source tag
    # @return [void]
    # @raise [Runtime::TypeMismatch] if `source` is present and not in `SOURCE_TAGS`
    def valid_source!(source)
      return if source.nil? || SOURCE_TAGS.include?(source.to_s)

      raise Runtime::TypeMismatch, "source: #{source.inspect} is not one of #{SOURCE_TAGS.join(', ')}"
    end

    # `actor_id` names who, `role` names what they hold — `Hecks.
    # as_caller` requires the latter always, the former is additive
    # (`Runtime::Caller::Current`'s own shape). An `actor_id` with no
    # `role` would silently do nothing rather than bind a real caller,
    # which is worse than refusing: a caller who thinks they've
    # identified themselves and haven't deserves to be told.
    #
    # @param role [String, Symbol, nil] the caller's self-asserted role
    # @param actor_id [String, nil] the caller's self-asserted identity
    # @return [void]
    # @raise [Runtime::TypeMismatch] if `actor_id` is given without `role`
    def valid_caller!(role, actor_id)
      return unless actor_id && role.nil?

      raise Runtime::TypeMismatch, "actor_id: requires role: too — a caller names WHO through WHICH role they hold"
    end

    # Bound for the duration of one call, then gone — `Hecks.as_caller`
    # is itself a `Thread.current`-scoped `ensure`-guarded block, so
    # nothing here needs its own cleanup. `role: nil` yields unbound —
    # for `query`, exactly as before: `CommandRules::Authorization#
    # refuse_role_mismatch` is opt-in on the domain side (`return unless
    # caller`), and query authorization runs on a wholly separate
    # mechanism (`authorize policy, tenant: :field`, checked against an
    # explicit `tenant:` argument — see `Runtime::TenantScope`), so
    # binding a caller around a query has no effect on it today; it is
    # still accepted here, for symmetry and for the audit log, against
    # the day a read model does check `Caller.current`. For `dispatch`,
    # `require_caller_for_role_gated!` (below) now refuses before this
    # is ever reached when the command declares a role and no caller is
    # bound — so an unbound `dispatch` here means either the command
    # declares no role at all, or a caller-side check let it through.
    #
    # @param role [String, Symbol, nil] the caller's self-asserted role; nil runs
    #   `block` unbound
    # @param actor_id [String, nil] the caller's self-asserted identity
    # @yield the dispatch/query to run, bound to the caller for its duration
    # @return [Object] the block's own return value
    def with_caller(role, actor_id, &block)
      return block.call if role.nil?

      Hecks.as_caller(role: role, actor_id: actor_id, &block)
    end

    # The fail-open half `with_caller` itself cannot close — ADR 0025's
    # Governance RBAC work fixed what a *bound* role is checked against
    # (a live `Governance::RoleAssignment` lookup instead of a bare
    # string match), but changed nothing about a caller who binds no
    # role at all: `refuse_role_mismatch` `return`s immediately when
    # `Caller.current` is nil, so a bus caller who simply omits `role:`
    # sails past a role-gated command unchecked, not denied. That is a
    # property of this bus choosing to dispatch unbound, not of the
    # domain rule — `bin/run`, the human CLI, has no such gap because a
    # human always dispatches through a real `Hecks.as_caller` binding
    # upstream of it. Refusing here, before `with_caller`/`dispatch` are
    # ever reached, makes the bus keep the same promise: a command whose
    # bluebook declares a role is not run through this bus without one.
    #
    # @param spec [Hash{Symbol => Object}] a resolved command spec (from `resolve!`),
    #   read for `:role_gated`, `:role` and `:verb`
    # @param role [String, Symbol, nil] the caller's self-asserted role
    # @return [void]
    # @raise [Runtime::Unauthorized] if `spec` is role-gated and `role` is nil
    def require_caller_for_role_gated!(spec, role)
      return unless spec[:role_gated] && role.nil?

      raise Runtime::Unauthorized,
            "#{spec[:verb]} requires role: #{spec[:role].inspect} — this command is role-gated and no caller " \
            "(role:/actor_id:) is bound; dispatching it unbound is refused, not silently unchecked"
    end

    # `dry_run?` (Runtime::Dispatcher) understands only the old flat
    # legacy args shape — no to:/with: envelope, `route:` never passed
    # (its own header explains why: built directly against
    # CommandInterpreter/EntityInterpreter's pre-envelope contract,
    # never updated because nothing else needed it to be — a real
    # record of history, not a defect this bus should paper over
    # silently). `Facade::CommandRequest`/`spec[:legacy_receiver]`
    # already know how to name that same flat shape for every receiver
    # kind (a bare id under one string key for :aggregate, a
    # {aggregate:, entity:} pair of keys for :entity) — this is the one
    # door back into it.
    #
    # @param envelope [Hash{Symbol => Object}] a normalized command request, with an
    #   optional `:to` route and `:with` facts
    # @param receiver [Symbol, nil] `:aggregate`, `:entity`, or nil for anything else
    # @param legacy_receiver [Symbol, String, Hash{Symbol => Symbol, String}, nil] where
    #   the route belongs in the flat shape: a single key for `:aggregate`, an
    #   `{aggregate:, entity:}` pair of keys for `:entity`
    # @return [Hash{Symbol => Object}] the facts, with the route merged in under its
    #   legacy key(s) when `envelope` carries one
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

    # The audit log file one domain's calls are appended to.
    #
    # @param domain_name [String, Symbol, #to_s] the domain name
    # @return [String] the absolute path to that domain's JSONL log file, under
    #   `LOG_ROOT`
    def log_path(domain_name)
      File.join(LOG_ROOT, "#{domain_name.to_s.gsub(/[^A-Za-z0-9_-]/, '_')}.jsonl")
    end

    # Appends one call's outcome to its domain's audit log.
    #
    # Never fails a real call because its own audit log couldn't be
    # written — a full disk or a permissions problem is a `follow`
    # feature going dark, not a reason to refuse the dispatch/query/
    # state call that was actually asked for.
    #
    # @param domain_name [String, Symbol, nil] the domain to log against; nil skips
    #   logging entirely (a call that never resolved a bluebook)
    # @param tool [String] which tool logged this: `"dispatch"`, `"dry_run"`,
    #   `"query"`, or `"state"`
    # @param summary [String, nil] the caller's one-line summary
    # @param source [String, Symbol, nil] the caller's source tag
    # @param outcome [Hash{Symbol => Object}] the call's own result, read for `:ok`,
    #   `:id`, `:error` and `:events`
    # @param verb [String, nil] the resolved verb dispatched or queried, when known
    # @param role [String, Symbol, nil] the caller's self-asserted role
    # @param actor_id [String, nil] the caller's self-asserted identity
    # @return [void]
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

    # `dry_run: true` answers a different question than a real dispatch
    # does — "would this succeed", not "here is what happened" — so a
    # domain refusal is the legitimate, complete answer (`ok: true,
    # would_succeed: false`), not a failed call. A malformed request
    # (unknown command, a bad args shape) is still a failed call
    # (`ok: false`) either way — it never reached the domain to be asked.
    #
    # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted runtime
    # @param command [String, Symbol] the command name, bare or qualified
    # @param summary [String] a one-line human summary of the call, for the audit log
    # @param args [Hash] the command's arguments
    # @param source [String, Symbol, nil] a `SOURCE_TAGS` tag naming who is calling
    # @param dry_run [Boolean] true to check whether the command would succeed,
    #   without actually dispatching it
    # @param role [String, Symbol, nil] the caller's self-asserted role
    # @param actor_id [String, nil] the caller's self-asserted identity
    # @return [Hash{Symbol => Object}] `:ok` plus, on success, `:id`/`:state`/`:events`
    #   (a real dispatch) or `:would_succeed`/`:error` (a dry run); on refusal, the
    #   shape `refused` returns
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

    # Validates and dispatches one command, real or dry-run.
    #
    # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted runtime
    # @param bluebook [Bluebook::Chapter] the domain's one loaded chapter
    # @param command [String, Symbol] the command name, bare or qualified
    # @param summary [String, nil] a one-line human summary of the call
    # @param args [Hash] the command's arguments, JSON-shaped
    # @param source [String, Symbol, nil] a `SOURCE_TAGS` tag naming who is calling
    # @param dry_run [Boolean] true to check whether the command would succeed,
    #   without actually dispatching it
    # @param role [String, Symbol, nil] the caller's self-asserted role
    # @param actor_id [String, nil] the caller's self-asserted identity
    # @return [Hash{Symbol => Object}] the outcome from `real_dispatch`/`dry_run_outcome`,
    #   merged with `:verb`
    # @raise [Runtime::TypeMismatch] if `summary`, `source`, or `actor_id` without
    #   `role` is invalid
    # @raise [Runtime::NotFound] if `command` names no known command
    # @raise [Runtime::Unauthorized] if `command` is role-gated and `role` is nil
    def perform_dispatch(runtime, bluebook, command, summary, args, source, dry_run, role, actor_id)
      require_summary!(summary)
      valid_source!(source)
      valid_caller!(role, actor_id)
      cli      = Projector.call(:cli, bluebook: bluebook, options: { program: "mcp" })
      spec     = resolve!(cli, command, asking: false)
      require_caller_for_role_gated!(spec, role)
      envelope = Facade::CommandRequest.normalize(Facade::JsonDoor.deep_symbolize(args),
                                                  receiver:        spec[:receiver],
                                                  legacy_receiver: spec[:legacy_receiver])

      result = with_caller(role, actor_id) do
        dry_run ? dry_run_outcome(runtime, spec, envelope, summary: summary) : real_dispatch(runtime, spec, envelope, summary)
      end
      result.merge(verb: spec[:verb])
    end

    # Dispatches one command for real and shapes its result for the bus.
    #
    # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted runtime
    # @param spec [Hash{Symbol => Object}] the resolved command spec (from `resolve!`)
    # @param envelope [Hash{Symbol => Object}] the normalized `to:`/`with:` request
    # @param summary [String, nil] a one-line human summary of the call
    # @return [Hash{Symbol => Object}] `:ok`, `:summary`, `:id`, `:state` (JSON-safe,
    #   nil for a port operation) and `:events` (name/payload pairs)
    def real_dispatch(runtime, spec, envelope, summary)
      result = runtime.dispatch_flat(spec[:verb], envelope)
      ok(summary: summary,
         id:      result.id,
         state:   result.state.nil? ? nil : Facade::JsonDoor.materialize(result.state),
         events:  result.events.map { |event| { name: event.name, payload: Facade::JsonDoor.materialize(event.payload) } })
    end

    # Checks whether one command would succeed, without dispatching it for real.
    #
    # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted runtime
    # @param spec [Hash{Symbol => Object}] the resolved command spec (from `resolve!`)
    # @param envelope [Hash{Symbol => Object}] the normalized `to:`/`with:` request
    # @param summary [String, nil] a one-line human summary of the call
    # @return [Hash{Symbol => Object}] `:ok`, `:summary`, `:would_succeed`, and
    #   `:error` (the refusal message) when it would not succeed
    def dry_run_outcome(runtime, spec, envelope, summary:)
      flat = flatten_legacy(envelope, spec[:receiver], spec[:legacy_receiver])
      runtime.dry_run?(spec[:verb], **flat)
      ok(summary: summary, would_succeed: true)
    rescue Runtime::WiringError, *Runtime::DOMAIN_REFUSALS => e
      ok(summary: summary, would_succeed: false, error: e.message)
    end

    # Dispatches a whole sequence of commands as one call.
    #
    # **One call, many steps** — the survey's own `bin/run <domain> script`
    # shape, so an agent issuing a known sequence of commands (open an
    # account, then fund it) pays one round trip instead of N. Every step
    # goes through `dispatch` itself — same resolution, same audit log
    # line per step, same summary/source stamped on all of them since
    # the batch is what the caller is declaring intent about, not each
    # individual step. Runs every step regardless of an earlier one
    # refusing — a later step naming a record an earlier step never
    # created will refuse honestly on its own account, which is more
    # informative than silently dropping the rest of the batch.
    #
    # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted runtime
    # @param steps [Array<Hash>] each step's `command`/`args`, JSON-shaped
    # @param summary [String] a one-line human summary of the whole batch
    # @param source [String, Symbol, nil] a `SOURCE_TAGS` tag naming who is calling
    # @param role [String, Symbol, nil] the caller's self-asserted role
    # @param actor_id [String, nil] the caller's self-asserted identity
    # @return [Hash{Symbol => Object}] `:ok` (true only if every step's own `:ok` was
    #   true), `:summary` and `:results` (each step's own `dispatch` outcome); on a
    #   refusal outside any one step, the shape `refused` returns
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

    # Answers one declared query.
    #
    # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted runtime
    # @param question [String, Symbol] the query name, bare or qualified
    # @param summary [String] a one-line human summary of the call, for the audit log
    # @param args [Hash] the query's arguments
    # @param source [String, Symbol, nil] a `SOURCE_TAGS` tag naming who is calling
    # @param role [String, Symbol, nil] the caller's self-asserted role
    # @param actor_id [String, nil] the caller's self-asserted identity
    # @return [Hash{Symbol => Object}] `:ok` and `:rows` (each JSON-safe) on success,
    #   or the shape `refused` returns
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

    # Validates and answers one query.
    #
    # @param bluebook [Bluebook::Chapter] the domain's one loaded chapter
    # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted runtime
    # @param question [String, Symbol] the query name, bare or qualified
    # @param summary [String, nil] a one-line human summary of the call
    # @param args [Hash] the query's arguments, JSON-shaped
    # @param source [String, Symbol, nil] a `SOURCE_TAGS` tag naming who is calling
    # @param role [String, Symbol, nil] the caller's self-asserted role
    # @param actor_id [String, nil] the caller's self-asserted identity
    # @return [Hash{Symbol => Object}] `:ok`, `:rows` (each JSON-safe) and `:verb`
    # @raise [Runtime::TypeMismatch] if `summary`, `source`, or `actor_id` without
    #   `role` is invalid
    # @raise [Runtime::NotFound] if `question` names no known query
    def perform_query(bluebook, runtime, question, summary, args, source, role, actor_id)
      require_summary!(summary)
      valid_source!(source)
      valid_caller!(role, actor_id)
      cli  = Projector.call(:cli, bluebook: bluebook, options: { program: "mcp" })
      spec = resolve!(cli, question, asking: true)
      rows = with_caller(role, actor_id) { runtime.query(spec[:verb], **Facade::JsonDoor.deep_symbolize(args)) }

      ok(summary: summary, rows: rows.map { |row| Facade::JsonDoor.materialize(row) }).merge(verb: spec[:verb])
    end

    # Reads one aggregate's stored records directly, bypassing any declared query.
    #
    # **What is actually stored** — no verb, no interpretation, the repository
    # itself. `id:` given answers one record (`NotFound` when it names
    # nothing); omitted answers every record the aggregate currently
    # holds. This is the difference `query` can't cover: a query answers a
    # declared question, and an aggregate that never declared "list
    # everything" has no query this could reuse.
    #
    # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted runtime
    # @param aggregate [String, Symbol] the aggregate's declared name
    # @param summary [String] a one-line human summary of the call, for the audit log
    # @param id [String, Object, nil] one record's identity, or nil for every record
    # @param source [String, Symbol, nil] a `SOURCE_TAGS` tag naming who is calling
    # @return [Hash{Symbol => Object}] `:ok` and, with `id:`, `:record`; without it,
    #   `:count` and `:records` (each JSON-safe); or the shape `refused` returns
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

    # Validates and reads one aggregate's stored record(s).
    #
    # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted runtime
    # @param bluebook [Bluebook::Chapter] the domain's one loaded chapter
    # @param aggregate [String, Symbol] the aggregate's declared name
    # @param summary [String, nil] a one-line human summary of the call
    # @param id [String, Object, nil] one record's identity, or nil for every record
    # @return [Hash{Symbol => Object}] `:ok` and, with `id`, `:record`; without it,
    #   `:count` and `:records` (each JSON-safe)
    # @raise [Runtime::TypeMismatch] if `summary` is invalid
    # @raise [Runtime::NotFound] if `aggregate` names no known aggregate, or `id`
    #   names no record of it
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

    # Lists every domain directory under a root.
    #
    # **Zoom level zero** — every domain directory a root actually holds,
    # discovered rather than typed from memory. Every other tool takes
    # `domain:` as a directory it assumes the caller already knows; this
    # is how a caller who doesn't finds out. `Adapters::Folder#domain?`
    # is the same predicate `domain_root`/`nearest_domain` already walk
    # up directories checking — a bare `.hecksagon` or one under
    # `bluebook/`, the two real shapes this corpus uses.
    #
    # @param under [String] the directory to search, relative to `BOOT_ROOT`
    # @return [Hash{Symbol => Object}] `:ok`, `:under`, and `:domains` (each found
    #   domain's path, relative to `BOOT_ROOT`, sorted); `:domains` is `[]` when
    #   `under` does not exist
    # @raise [Runtime::TypeMismatch] if `under` resolves outside `BOOT_ROOT`
    def domains(under: "examples")
      root = confine!(under, "under")
      return ok(under: under, domains: []) unless Dir.exist?(root)

      folder = Adapters::Folder.new
      found  = Dir.children(root).sort.select { |name| folder.domain?(File.join(root, name)) }

      ok(under: under, domains: found.map { |name| File.join(under, name) })
    end

    # Lists a domain's aggregates and their command/query names.
    #
    # **Zoom level one** — every aggregate this domain declares, and every
    # command/query name each answers to, snake_cased exactly as
    # `dispatch`/`query` want it. Enough to pick a target; `describe` is
    # the next level down for what one of them actually takes.
    #
    # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted runtime
    # @return [Hash{Symbol => Object}] `:ok`, `:domain`, and `:aggregates` — an Array
    #   of `{name:, commands:, queries:}` Hashes, commands and queries sorted,
    #   command names suffixed `!`; or the shape `refused` returns
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

    # Answers one aggregate's (or the whole chapter's) full usage documentation.
    #
    # **Zoom level two** — the exact same usage document a human gets from
    # `bin/docs <domain> [aggregate]` (`Projector::DocsProjector`, the
    # identical projection `Surface::AggregateDoor#docs` calls one door
    # over): every command's arguments, the states it may be issued
    # from, and every way it can refuse. `aggregate:` omitted answers the
    # whole chapter.
    #
    # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted runtime
    # @param aggregate [String, Symbol, nil] one aggregate's name, or nil for the
    #   whole chapter
    # @return [Hash{Symbol => Object}] `:ok`, `:domain` and `:docs` (the rendered
    #   documentation); or the shape `refused` returns
    # @raise [Runtime::NotFound] if `aggregate` names no known aggregate
    def describe(runtime:, aggregate: nil)
      bluebook = bluebook_for(runtime)
      options  = aggregate ? { aggregate: aggregate_ir!(bluebook, aggregate).hecks_name } : {}

      ok(domain: bluebook.name, docs: Projector.call(:docs, bluebook: bluebook, options: options))
    rescue *refusal_classes => e
      refused(e)
    end

    # Boots a domain and reports whether its wiring (and, optionally, its logic) is sound.
    #
    # **Zoom level three** — is the wiring sound at all: every bind names a
    # declared aggregate, every adapter satisfies the port it claims, the
    # default adapter is usable. `Registry#verify!` (`runtime/registry/
    # verification.rb`) is the one place this repo already answers that
    # question, and `Runtime::Loader.boot` already calls it as the last
    # step of every boot — so this is the one method here that boots for
    # itself rather than taking a `runtime:` already in hand, because a
    # runtime that successfully reached this line already answered the
    # question. Given a domain path, not a booted runtime, deliberately:
    # asking "is this valid" about a domain that failed to boot at all
    # has to be askable without a runtime to hand it.
    #
    # `deep: true` goes past wiring into logic — `Bluebook::ModelCheck`,
    # the lightweight-formal-methods leg (dead lifecycle transitions, a
    # saga state no handler chain reaches, a dispatch to nowhere). Opt-in
    # and separate from the base check on purpose: a wiring defect is
    # "this cannot run at all", a model-check finding is "this runs, but
    # part of it can never fire" — two different questions, and the
    # first is far cheaper to ask on every boot.
    #
    # Any boot failure answers the question, not only `WiringError` — a
    # domain path with no `.hecksagon`, a malformed bluebook, is just as
    # much "not valid" as a real wiring mismatch, and this tool exists
    # precisely so none of those ever cross a projection of this bus as
    # a crash.
    #
    # @param domain [String] the domain's directory path, relative to `BOOT_ROOT`
    # @param deep [Boolean] also run `Bluebook::ModelCheck` past wiring, into logic
    # @return [Hash{Symbol => Object}] `{ok: true, domain:, valid: true}`, plus
    #   `:findings` (each `{kind:, severity:, subject:, message:}`) when `deep`; or
    #   `{ok: false, domain:, valid: false, error:}` if the boot itself failed
    def validate(domain:, deep: false)
      runtime = Hecks.boot(confine!(domain, "domain"), install_facade: false)
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

    # The full write history, not just the current head — `bin/history`'s
    # own logic, unchanged: every operation that ever touched the
    # aggregate, read off its repository's own `entries`. `Registry#repository`
    # always hands back a `Ports::Persistence::AppendOnly`-wrapped adapter,
    # never the bare adapter, so this never needs to guard against one —
    # what varies by adapter is only how much the wrapped `entries` itself
    # actually holds: a fresh Memory boot honestly has none yet, and a
    # durable adapter (Heki, Postgres, SQLite, D1) has whatever it
    # journaled.
    #
    # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted runtime
    # @return [Hash{Symbol => Object}] `:ok`, `:domain` and `:history` (each
    #   aggregate's storage name mapped to its `journal_entries`); or the shape
    #   `refused` returns
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

    # One aggregate's full append-only write history, JSON-safe.
    #
    # @param repository [Ports::Persistence::AppendOnly] the aggregate's repository, as
    #   `Registry#repository` always returns it
    # @return [Array<Hash>] each journal entry's `:operation`, `:id` and `:state`
    #   (materialized); `[]` when the adapter has journaled nothing yet
    def journal_entries(repository)
      repository.entries.map { |entry| { operation: entry.operation, id: entry.id, state: Facade::JsonDoor.materialize(entry.state) } }
    end

    # `.behaviors` files, run and reported — hand-curated examples of how
    # to use a domain, in domain vocabulary (`docs/guides/behaviors.md`),
    # the survey's own "honest-refusal", generated-example-suite items.
    # `Hecks::Behaviors` boots each test fresh through `Hecks.boot_files`
    # itself — `target:` names a `.behaviors` file or a directory to
    # sweep, never a `runtime:`, the one other method here besides
    # `validate` that takes a path instead.
    #
    # @param target [String] a `.behaviors` file's path, or a directory to sweep
    #   for every `.behaviors` file under it
    # @return [Hash{Symbol => Object}] `:ok`, `:target`, `:files` (each file's own
    #   `behaviors_file` shape) and `:counts` (`Behaviors.summarize`'s tally); or
    #   the shape `refused` returns
    # @raise [Runtime::NotFound] if `target` is nil or names no real file or directory
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

    # Shapes one `.behaviors` file's own result for the bus.
    #
    # @param result [Behaviors::FileResult] one file's run result
    # @return [Hash{Symbol => Object}] `:path`, `:parse_error`, and `:runs` (each
    #   test's `description`/`status`/`message`)
    def behaviors_file(result)
      { path:        result.path,
        parse_error: result.parse_error,
        runs:        Array(result.runs).map { |run| { description: run.description, status: run.status, message: run.message } } }
    end

    # A live tail without a live process — `bin/hecks_mcp_door` (its
    # transport of MCP-over-stdio) answers one request at a time, no push
    # channel to a client that only ever asks. This is the honest version
    # of the survey's `storehouse follow` for that shape: not a
    # subscription, a durable JSONL log every `dispatch`/`query`/`state`/
    # dry-run call appends to (`record!`), tailed back here. Still real,
    # still cross-process — the log outlives any one door's own process —
    # just pull instead of push.
    #
    # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted runtime
    # @param limit [Integer, #to_i] how many of the most recent log entries to return;
    #   clamped to at least 1
    # @return [Hash{Symbol => Object}] `:ok`, `:domain` and `:entries` (each logged
    #   call's own JSON entry); or the shape `refused` returns
    def follow(runtime:, limit: 20)
      bluebook = bluebook_for(runtime)
      entries  = log_lines(bluebook.name).last([limit.to_i, 1].max)

      ok(domain: bluebook.name, entries: entries)
    rescue *refusal_classes => e
      refused(e)
    end

    # Reads back one domain's whole audit log.
    #
    # @param domain_name [String, Symbol, #to_s] the domain name
    # @return [Array<Hash>] every logged entry, parsed with Symbol keys, in log
    #   order; `[]` if the domain has no log file yet
    def log_lines(domain_name)
      path = log_path(domain_name)
      return [] unless File.exist?(path)

      File.readlines(path).map { |line| JSON.parse(line, symbolize_names: true) }
    end

    # What actually happened, with payloads — distinct from `state`
    # (what's stored now) and `history` (append-only operation
    # snapshots, no payload). Not a domain-wide event-sourcing replay:
    # "one boot per call" means `runtime.events` is always empty except
    # during the very call that populated it, discarded the moment that
    # call returns — there is no cross-call in-memory log to read here.
    # So this reads the same durable audit log `follow` already tails
    # (`record!` now stamps a successful dispatch's own announced
    # events onto its log line), reshaped: `follow` answers "what was
    # called, in order, across every tool"; this answers "what happened
    # to one aggregate/record" — events this bus witnessed, which is
    # every real dispatch ever routed through it, but no more than that.
    # `aggregate:` narrows to one aggregate; `id:` (requires
    # `aggregate:` — an id alone is not unique across aggregates)
    # narrows to one record's own events.
    #
    # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted runtime
    # @param aggregate [String, Symbol, nil] narrows to one aggregate's own events
    # @param id [String, Object, nil] narrows to one record's own events; requires
    #   `aggregate`
    # @param limit [Integer, #to_i, nil] how many of the most recent matching events
    #   to return; nil returns every one found
    # @return [Hash{Symbol => Object}] `:ok`, `:domain` and `:events` (each with
    #   `:name`, `:payload`, `:time`, `:verb` and `:id`); or the shape `refused` returns
    # @raise [Runtime::TypeMismatch] if `id` is given without `aggregate`
    # @raise [Runtime::NotFound] if `aggregate` names no known aggregate
    def events(runtime:, aggregate: nil, id: nil, limit: nil)
      raise Runtime::TypeMismatch, "id: requires aggregate: too — an id alone is not unique across aggregates" if id && !aggregate

      bluebook = bluebook_for(runtime)
      fqn      = aggregate ? "#{bluebook.name}::#{aggregate_ir!(bluebook, aggregate).hecks_name}" : nil

      found = log_lines(bluebook.name).filter_map { |entry| entry_events(entry, fqn, id) }.flatten(1)
      found = found.last(limit.to_i) if limit

      ok(domain: bluebook.name, events: found)
    rescue *refusal_classes => e
      refused(e)
    end

    # One log line's own contribution to `events`, above — nil unless it
    # was a successful dispatch carrying events, matching `fqn` (when an
    # aggregate narrowed the search) and `id` (when a record did). A
    # self-contained per-entry check with nothing to share with its
    # neighbors, extracted only to keep `events` itself to the query's
    # own shape: build the filter, apply the limit, wrap the result.
    #
    # @param entry [Hash{Symbol => Object}] one logged audit entry
    # @param fqn [String, nil] narrows to a dispatch whose verb starts with this
    #   aggregate FQN; nil matches any aggregate
    # @param id [String, Object, nil] narrows to a dispatch whose settled record has
    #   this id; nil matches any record
    # @return [Array<Hash>, nil] `entry`'s own events (each with `:time`, `:verb` and
    #   `:id` merged in), or nil if `entry` isn't a matching successful dispatch
    def entry_events(entry, fqn, id)
      return unless entry[:tool] == "dispatch" && entry[:ok] && entry[:events]
      return if fqn && !entry[:verb].to_s.start_with?("#{fqn}.")
      return if id && entry[:id] != id

      entry[:events].map { |event| event.merge(time: entry[:time], verb: entry[:verb], id: entry[:id]) }
    end

    # ── shared shape ────────────────────────────────────────────────────

    # `Runtime::WiringError` belongs here too, alongside the true domain
    # refusals — not because it is one (it's a structural defect, not a
    # rule the caller broke), but because "this domain isn't wired to
    # answer what you're asking" (a `role:`+`actor_id:` caller reaching
    # an authorization port nothing implements, a dry run against a
    # port verb) is exactly the shape this bus promises never crashes
    # through it. `dry_run_outcome` already treats it this way locally;
    # this makes every other caller of `refusal_classes` do the same.
    #
    # @return [Array<Class>] every exception class this bus catches and reshapes
    #   into an honest refusal rather than letting crash through
    def refusal_classes = [Runtime::NotFound, Runtime::TypeMismatch, Runtime::WiringError, *Runtime::DOMAIN_REFUSALS]

    # Builds a successful outcome Hash.
    #
    # @param fields [Hash{Symbol => Object}] fields to merge in alongside `ok: true`
    # @return [Hash{Symbol => Object}] `{ok: true}` merged with `fields`
    def ok(**fields) = { ok: true }.merge(fields)

    # Builds a refused outcome Hash from a caught exception.
    #
    # **An honest refusal, not a crash** — the survey's own item #9: "an
    # explicit, structured refusal a caller can act on" rather than a
    # stack trace an agent has to parse to find the one line that
    # mattered. The domain's own refusal text travels verbatim
    # (`RefusalWording` already renders every one of these to be read),
    # this only wraps it consistently.
    #
    # @param error [StandardError] the caught exception, a member of `refusal_classes`
    # @param summary [String, nil] the caller's one-line summary
    # @return [Hash{Symbol => Object}] `{ok: false, summary:, error:}`
    def refused(error, summary: nil) = { ok: false, summary: summary, error: error.message }
  end
end
