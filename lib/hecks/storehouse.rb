require "json"
require "fileutils"
require "time"
require_relative "facade/command_request"
require_relative "facade/json_door"
require_relative "naming"
require_relative "projector"
require_relative "runtime/errors"

module Hecks
  # The bus, not a door — `docs/hecks-survey-what-we-wish-we-had.md` and
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
  # ever needing to speak MCP. It lives here, under `Hecks` rather than
  # `Facade`, precisely because it is the bus and not one particular
  # transport.
  #
  # ## What each method does
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
  # ## `summary:`, `source:`, `role:` and `actor_id:`
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
  # ## An already-booted `runtime`
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
  # ## No new vocabulary
  #
  # Every method here composes doors that
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

    # Resolves `path` against `BOOT_ROOT` and refuses it if it escapes that root.
    #
    # Refused, not silently clamped — a path outside `BOOT_ROOT` is either
    # an honest mistake (a relative path typed against the wrong cwd) or
    # the exact thing this check exists to catch, and both deserve the
    # same clear refusal rather than a silent rewrite to something the
    # caller didn't ask for.
    #
    # @param path [String] the path to confine, relative or absolute
    # @param label [String] what to call `path` in the refusal message, such as `"domain"`
    # @return [String] `path` resolved to an absolute path under `BOOT_ROOT`
    # @raise [Runtime::TypeMismatch] if the resolved path is not `BOOT_ROOT` itself or
    #   under it
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
    # Names the one bluebook this boot loaded.
    #
    # @param runtime [Runtime::Dispatcher] the booted runtime to read
    # @return [Bluebook::Chapter] the first (and, for this bus, only) chapter the boot
    #   registered
    # @raise [Runtime::NotFound] if the boot registered no bluebook
    def bluebook_for(runtime)
      runtime.registry.bluebooks.values.first or
        raise Runtime::NotFound, "this boot loaded no bluebook"
    end

    # Finds one aggregate's IR by name, refusing an unknown one with the full list of
    # what the chapter does declare.
    #
    # @param bluebook [Bluebook::Chapter] the chapter to search
    # @param name [String, Symbol] the aggregate's declared name
    # @return [Bluebook::Aggregate] the matching aggregate's IR
    # @raise [Runtime::NotFound] if the chapter declares no aggregate of that name
    def aggregate_ir!(bluebook, name)
      bluebook.aggregate(name) or
        raise Runtime::NotFound, "#{bluebook.name} declares no aggregate named #{name.inspect} — " \
                                 "known: #{bluebook.aggregates.map(&:hecks_name).sort.join(', ')}"
    end

    # Resolves a typed verb or question name to its projected CLI spec, against the same
    # alias table `CliRunner` resolves a typed word against — a
    # short name when it's unambiguous, the qualified `Aggregate.Verb`
    # form always. Shared here so `dispatch` and `query` (and their error
    # messages) never drift from what a human typing `bin/run` sees.
    #
    # @param cli [Hash{Symbol => Object}] the `Projector::CliProjector` projection
    # @param name [String] the verb or question name as typed, bare or qualified
    # @param asking [Boolean] true to resolve against questions, false against commands
    # @return [Hash{Symbol => Object}] the matching verb's projected spec
    # @raise [Runtime::NotFound] if no verb or question resolves to that name
    def resolve!(cli, name, asking:)
      pool = asking ? cli[:questions] : cli[:verbs]
      key  = cli[:names][asking ? :question : :command][name]
      spec = pool[key]
      return spec if spec

      known = cli[:names][asking ? :question : :command].keys.sort.join(", ")
      raise Runtime::NotFound, "no such #{asking ? 'query' : 'command'}: #{name.inspect} — known: #{known}"
    end

    # Refuses a call with no summary, or one that is blank.
    #
    # @param summary [String, nil] the caller-supplied summary
    # @return [void]
    # @raise [Runtime::TypeMismatch] if `summary` is `nil` or, once stripped, empty
    def require_summary!(summary)
      return unless summary.nil? || summary.to_s.strip.empty?

      raise Runtime::TypeMismatch,
            "a one-line summary: is required on dispatch/query/state — it is what makes an audit row legible later"
    end

    # Refuses a source tag outside the declared `SOURCE_TAGS` set.
    #
    # @param source [String, Symbol, nil] the caller-supplied source; `nil` is accepted
    # @return [void]
    # @raise [Runtime::TypeMismatch] if `source` is given and is not one of `SOURCE_TAGS`
    def valid_source!(source)
      return if source.nil? || SOURCE_TAGS.include?(source.to_s)

      raise Runtime::TypeMismatch, "source: #{source.inspect} is not one of #{SOURCE_TAGS.join(', ')}"
    end

    # Refuses an `actor_id` given without a `role`.
    #
    # `actor_id` names who, `role` names what they hold — `Hecks.
    # as_caller` requires the latter always, the former is additive
    # (`Runtime::Caller::Current`'s own shape). An `actor_id` with no
    # `role` would silently do nothing rather than bind a real caller,
    # which is worse than refusing: a caller who thinks they've
    # identified themselves and haven't deserves to be told.
    #
    # @param role [String, Symbol, nil] the caller-supplied role
    # @param actor_id [String, nil] the caller-supplied identity
    # @return [void]
    # @raise [Runtime::TypeMismatch] if `actor_id` is given and `role` is `nil`
    def valid_caller!(role, actor_id)
      return unless actor_id && role.nil?

      raise Runtime::TypeMismatch, "actor_id: requires role: too — a caller names WHO through WHICH role they hold"
    end

    # Runs the block with `role`/`actor_id` bound as the current caller, or unbound when
    # `role` is `nil`.
    #
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
    # @param role [String, Symbol, nil] the role to bind; `nil` runs the block unbound
    # @param actor_id [String, nil] the identity to bind alongside `role`
    # @yield the call to run, bound or unbound
    # @return [Object] whatever the block returns
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
    # @param spec [Hash{Symbol => Object}] the verb's projected CLI spec; read for
    #   `:role_gated` and `:role`/`:verb` in the refusal message
    # @param role [String, Symbol, nil] the caller-supplied role, if any
    # @return [void]
    # @raise [Runtime::Unauthorized] if the verb is role-gated and `role` is `nil`
    def require_caller_for_role_gated!(spec, role)
      return unless spec[:role_gated] && role.nil?

      raise Runtime::Unauthorized,
            "#{spec[:verb]} requires role: #{spec[:role].inspect} — this command is role-gated and no caller " \
            "(role:/actor_id:) is bound; dispatching it unbound is refused, not silently unchecked"
    end

    # Flattens a `to:`/`with:` envelope back into the legacy flat-args shape
    # `Dispatcher#dry_run?` understands.
    #
    # `dry_run?` (Runtime::Dispatcher) understands only the old flat
    # legacy args shape — no to:/with: envelope, `route:` never passed
    # (built directly against CommandInterpreter/EntityInterpreter's
    # pre-envelope contract, never updated because nothing else needed
    # it to be). `Facade::CommandRequest`/`spec[:legacy_receiver]`
    # already know how to name that same flat shape for every receiver
    # kind (a bare id under one string key for :aggregate, a
    # {aggregate:, entity:} pair of keys for :entity) — this is the one
    # door back into it.
    #
    # @param envelope [Hash{Symbol => Object}] `CommandRequest.normalize`'s own result:
    #   `:with` facts, plus `:to` when the receiver takes one
    # @param receiver [Symbol, nil] the receiver kind: `:aggregate`, `:entity`, or `nil`
    # @param legacy_receiver [Symbol, String, Hash{Symbol => Symbol, String}, nil] where
    #   the flattened receiver goes: one key for `:aggregate`, a pair of keys for
    #   `:entity`
    # @return [Hash{Symbol => Object}] the facts, merged with the flattened receiver
    #   under its legacy key(s); the facts unchanged when `envelope` carries no `:to`
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

    # Names one domain's own audit log file under `LOG_ROOT`.
    #
    # @param domain_name [String, Symbol, nil] the booted bluebook's name
    # @return [String] the log file's absolute path, its name stripped to safe filename
    #   characters
    def log_path(domain_name)
      File.join(LOG_ROOT, "#{domain_name.to_s.gsub(/[^A-Za-z0-9_-]/, '_')}.jsonl")
    end

    # Appends one JSONL line to a domain's own audit log, silently doing nothing if it
    # cannot be written.
    #
    # Never fails a real call because its own audit log couldn't be
    # written — a full disk or a permissions problem is a `follow`
    # feature going dark, not a reason to refuse the dispatch/query/
    # state call that was actually asked for.
    #
    # @param domain_name [String, Symbol, nil] the bluebook's name; `nil` skips logging
    #   entirely, such as when a boot failed before any bluebook was found
    # @param tool [String] which method logged this: `"dispatch"`, `"dry_run"`,
    #   `"query"`, or `"state"`
    # @param summary [String, nil] the caller's own summary
    # @param source [String, Symbol, nil] the caller's own source tag
    # @param outcome [Hash{Symbol => Object}] the call's own result Hash, read for
    #   `:ok`, `:id`, `:error` and `:events`; any not present are omitted from the entry
    # @param verb [String, nil] the resolved verb's FQN, when the call reached resolution
    # @param role [String, Symbol, nil] the bound caller's role, if any
    # @param actor_id [String, nil] the bound caller's identity, if any
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

    # Issues one command, or previews it, resolving the verb, checking role-gating,
    # dispatching, and logging the call to the domain's audit log.
    #
    # `dry_run: true` answers a different question than a real dispatch
    # does — "would this succeed", not "here is what happened" — so a
    # domain refusal is the legitimate, complete answer (`ok: true,
    # would_succeed: false`), not a failed call. A malformed request
    # (unknown command, a bad args shape) is still a failed call
    # (`ok: false`) either way — it never reached the domain to be asked.
    #
    # @param runtime [Runtime::Dispatcher] the booted runtime to dispatch against
    # @param command [String] the command name, bare or qualified, as `bin/run` accepts
    # @param summary [String] a one-line human summary, required, recorded to the audit
    #   log
    # @param args [Hash{Symbol => Object}] the command's facts and, when needed, its
    #   receiver identity, mixed together the way `Facade::CommandRequest.normalize`
    #   accepts
    # @param source [String, Symbol, nil] one of `SOURCE_TAGS` naming who is calling;
    #   `nil` records honestly as no source
    # @param dry_run [Boolean] true to check whether the command would succeed without
    #   running it
    # @param role [String, Symbol, nil] the caller's self-asserted role, bound for the
    #   call's duration; required when the resolved command is role-gated
    # @param actor_id [String, nil] the caller's self-asserted identity, bound alongside
    #   `role`
    # @return [Hash{Symbol => Object}] on success: `{ok: true, summary:, id:, state:,
    #   events:}` for a real dispatch, or `{ok: true, summary:, would_succeed:, error:}`
    #   for a dry run; on any refusal caught by `refusal_classes` (including an unknown
    #   command, a malformed request, a role-gated command with no bound caller, or a
    #   domain refusal): `{ok: false, summary:, error:}`
    # @raise [Runtime::StaleWrite] if concurrent writers beat this dispatch through every
    #   retry; not one of `refusal_classes`, so it propagates rather than becoming a
    #   `{ok: false}` outcome
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

    # Validates a dispatch call, resolves its verb, normalizes its envelope, and runs it
    # (or previews it) with the caller bound.
    #
    # @param runtime [Runtime::Dispatcher] the booted runtime to dispatch against
    # @param bluebook [Bluebook::Chapter] the booted chapter, for CLI projection
    # @param command [String] the command name as `dispatch` received it
    # @param summary [String] the caller's one-line summary
    # @param args [Hash{Symbol => Object}] the command's facts and receiver, as `dispatch`
    #   received them
    # @param source [String, Symbol, nil] the caller's source tag
    # @param dry_run [Boolean] true to preview rather than run
    # @param role [String, Symbol, nil] the caller's role to bind
    # @param actor_id [String, nil] the caller's identity to bind
    # @return [Hash{Symbol => Object}] `real_dispatch`'s or `dry_run_outcome`'s own
    #   result Hash, with `:verb` merged in as the resolved FQN
    # @raise [Runtime::TypeMismatch] if `summary` is blank, `source` is not a declared
    #   tag, `actor_id` is given without `role`, or the args cannot be normalized into a
    #   valid envelope
    # @raise [Runtime::NotFound] if `command` resolves to no known verb
    # @raise [Runtime::Unauthorized] if the resolved command is role-gated and no `role`
    #   is given
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

    # Dispatches the resolved command for real and shapes the settled result.
    #
    # @param runtime [Runtime::Dispatcher] the booted runtime to dispatch against
    # @param spec [Hash{Symbol => Object}] the resolved verb's projected CLI spec; read
    #   for `:verb`
    # @param envelope [Hash{Symbol => Object}] the normalized `to:`/`with:` envelope
    # @param summary [String] the caller's one-line summary, carried into the result
    # @return [Hash{Symbol => Object}] `{ok: true, summary:, id:, state:, events:}`;
    #   `state` is `nil` for a port operation, which hydrates no record; `events` is one
    #   `{name:, payload:}` Hash per announced event
    # @raise [StandardError] any class in `Runtime::DOMAIN_REFUSALS` when the domain
    #   refuses the call
    # @raise [Runtime::StaleWrite] if concurrent writers beat this one through every retry
    # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
    def real_dispatch(runtime, spec, envelope, summary)
      result = runtime.dispatch_flat(spec[:verb], envelope)
      ok(summary: summary,
         id:      result.id,
         state:   result.state.nil? ? nil : Facade::JsonDoor.materialize(result.state),
         events:  result.events.map { |event| { name: event.name, payload: Facade::JsonDoor.materialize(event.payload) } })
    end

    # Checks whether the resolved command would succeed, without running it, catching a
    # domain refusal as the (complete, legitimate) answer rather than letting it propagate.
    #
    # @param runtime [Runtime::Dispatcher] the booted runtime to check against
    # @param spec [Hash{Symbol => Object}] the resolved verb's projected CLI spec; read
    #   for `:verb`, `:receiver` and `:legacy_receiver`
    # @param envelope [Hash{Symbol => Object}] the normalized `to:`/`with:` envelope
    # @param summary [String] the caller's one-line summary, carried into the result
    # @return [Hash{Symbol => Object}] `{ok: true, summary:, would_succeed: true}` when
    #   the check raises nothing; `{ok: true, summary:, would_succeed: false, error:}`
    #   when it would refuse
    def dry_run_outcome(runtime, spec, envelope, summary:)
      flat = flatten_legacy(envelope, spec[:receiver], spec[:legacy_receiver])
      runtime.dry_run?(spec[:verb], **flat)
      ok(summary: summary, would_succeed: true)
    rescue Runtime::WiringError, *Runtime::DOMAIN_REFUSALS => e
      ok(summary: summary, would_succeed: false, error: e.message)
    end

    # Runs a sequence of steps through `dispatch`, one call, many steps — the survey's
    # own `bin/run <domain> script` shape, so an agent issuing a known sequence of
    # commands (open an account, then fund it) pays one round trip instead of N. Every
    # step goes through `dispatch` itself — same resolution, same audit log
    # line per step, same summary/source stamped on all of them since
    # the batch is what the caller is declaring intent about, not each
    # individual step. Runs every step regardless of an earlier one
    # refusing — a later step naming a record an earlier step never
    # created will refuse honestly on its own account, which is more
    # informative than silently dropping the rest of the batch.
    #
    # @param runtime [Runtime::Dispatcher] the booted runtime to dispatch each step against
    # @param steps [Array<Hash>] each step's `command`/`args`, with String or Symbol keys
    # @param summary [String] one summary for the whole batch, stamped on every step
    # @param source [String, Symbol, nil] one source tag for the whole batch
    # @param role [String, Symbol, nil] one caller role bound for every step
    # @param actor_id [String, nil] one caller identity bound for every step
    # @return [Hash{Symbol => Object}] `{ok:, summary:, results:}`, `ok` true only when
    #   every step's own outcome is `ok`; `results` one `dispatch` outcome per step, in
    #   order
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

    # Answers one declared question, resolving the question name, checking the caller,
    # and logging the call to the domain's audit log.
    #
    # @param runtime [Runtime::Dispatcher] the booted runtime to query
    # @param question [String] the question name, bare or qualified
    # @param summary [String] a one-line human summary, required, recorded to the audit
    #   log
    # @param args [Hash{Symbol => Object}] the question's arguments
    # @param source [String, Symbol, nil] one of `SOURCE_TAGS` naming who is calling;
    #   `nil` records honestly as no source
    # @param role [String, Symbol, nil] the caller's self-asserted role, bound for the
    #   call's duration (query authorization does not check it today — see this file's
    #   own header)
    # @param actor_id [String, nil] the caller's self-asserted identity, bound alongside
    #   `role`
    # @return [Hash{Symbol => Object}] `{ok: true, summary:, rows:}` on success; `{ok:
    #   false, summary:, error:}` on any refusal caught by `refusal_classes`
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

    # Validates a query call, resolves its question, and runs it with the caller bound.
    #
    # @param bluebook [Bluebook::Chapter] the booted chapter, for CLI projection
    # @param runtime [Runtime::Dispatcher] the booted runtime to query
    # @param question [String] the question name as `query` received it
    # @param summary [String] the caller's one-line summary
    # @param args [Hash{Symbol => Object}] the question's arguments
    # @param source [String, Symbol, nil] the caller's source tag
    # @param role [String, Symbol, nil] the caller's role to bind
    # @param actor_id [String, nil] the caller's identity to bind
    # @return [Hash{Symbol => Object}] `{ok: true, summary:, rows:, verb:}`, each row
    #   materialized to plain data
    # @raise [Runtime::TypeMismatch] if `summary` is blank, `source` is not a declared
    #   tag, `actor_id` is given without `role`, or an argument cannot be coerced to its
    #   declared type
    # @raise [Runtime::NotFound] if `question` resolves to no known query, or a read
    #   model's root reference names no record
    # @raise [KeyError] if a rooted read model is asked without its reference argument
    # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
    def perform_query(bluebook, runtime, question, summary, args, source, role, actor_id)
      require_summary!(summary)
      valid_source!(source)
      valid_caller!(role, actor_id)
      cli  = Projector.call(:cli, bluebook: bluebook, options: { program: "mcp" })
      spec = resolve!(cli, question, asking: true)
      rows = with_caller(role, actor_id) { runtime.query(spec[:verb], **Facade::JsonDoor.deep_symbolize(args)) }

      ok(summary: summary, rows: rows.map { |row| Facade::JsonDoor.materialize(row) }).merge(verb: spec[:verb])
    end

    # Reads a record, or every record, straight off the repository — no verb, no
    # interpretation, the repository itself. `id:` given answers one record (`NotFound`
    # when it names nothing); omitted answers every record the aggregate currently
    # holds. This is the difference `query` can't cover: a query answers a
    # declared question, and an aggregate that never declared "list
    # everything" has no query this could reuse.
    #
    # @param runtime [Runtime::Dispatcher] the booted runtime to read
    # @param aggregate [String, Symbol] the aggregate's declared name
    # @param summary [String] a one-line human summary, required, recorded to the audit
    #   log
    # @param id [String, nil] one record's identity; `nil` reads every record
    # @param source [String, Symbol, nil] one of `SOURCE_TAGS` naming who is calling
    # @return [Hash{Symbol => Object}] `{ok: true, summary:, record:}` when `id` is
    #   given; `{ok: true, summary:, count:, records:}` when it is not; `{ok: false,
    #   summary:, error:}` on any refusal caught by `refusal_classes`
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

    # Validates a state call and reads the named aggregate's repository directly.
    #
    # @param runtime [Runtime::Dispatcher] the booted runtime to read
    # @param bluebook [Bluebook::Chapter] the booted chapter, to resolve `aggregate`
    #   against
    # @param aggregate [String, Symbol] the aggregate's declared name
    # @param summary [String] the caller's one-line summary
    # @param id [String, nil] one record's identity; `nil` reads every record
    # @return [Hash{Symbol => Object}] `{ok: true, summary:, record:}` for one record;
    #   `{ok: true, summary:, count:, records:}` for every record
    # @raise [Runtime::TypeMismatch] if `summary` is blank
    # @raise [Runtime::NotFound] if `aggregate` names no declared aggregate, or `id` is
    #   given and the repository holds no such record
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

    # Lists every domain directory a root actually holds — zoom level zero, discovered
    # rather than typed from memory. Every other tool takes
    # `domain:` as a directory it assumes the caller already knows; this
    # is how a caller who doesn't finds out. `Adapters::Folder#domain?`
    # is the same predicate `domain_root`/`nearest_domain` already walk
    # up directories checking — a bare `.hecksagon` or one under
    # `bluebook/`, the two real shapes this corpus uses.
    #
    # @param under [String] a directory, relative to `BOOT_ROOT`, to search
    # @return [Hash{Symbol => Object}] `{ok: true, under:, domains:}`, `domains` one path
    #   (relative the same way `under` was given) per discovered domain, sorted; `[]`
    #   when `under` does not exist
    # @raise [Runtime::TypeMismatch] if `under` resolves outside `BOOT_ROOT`
    def domains(under: "examples")
      root = confine!(under, "under")
      return ok(under: under, domains: []) unless Dir.exist?(root)

      folder = Adapters::Folder.new
      found  = Dir.children(root).sort.select { |name| folder.domain?(File.join(root, name)) }

      ok(under: under, domains: found.map { |name| File.join(under, name) })
    end

    # Lists a domain's aggregates and their command/query names — zoom level one:
    # every aggregate this domain declares, and every
    # command/query name each answers to, snake_cased exactly as
    # `dispatch`/`query` want it. Enough to pick a target; `describe` is
    # the next level down for what one of them actually takes.
    #
    # @param runtime [Runtime::Dispatcher] the booted runtime to catalog
    # @return [Hash{Symbol => Object}] `{ok: true, domain:, aggregates:}`, `aggregates`
    #   one `{name:, commands:, queries:}` Hash per aggregate, both name lists sorted;
    #   `{ok: false, error:}` if the boot loaded no bluebook
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

    # Answers one aggregate's, or a whole chapter's, full usage document — zoom level
    # two, the exact same usage document a human gets from
    # `bin/docs <domain> [aggregate]` (`Projector::DocsProjector`, the
    # identical projection `Surface::AggregateDoor#docs` calls one door
    # over): every command's arguments, the states it may be issued
    # from, and every way it can refuse.
    #
    # @param runtime [Runtime::Dispatcher] the booted runtime to describe
    # @param aggregate [String, Symbol, nil] narrows the document to one aggregate;
    #   `nil` answers the whole chapter
    # @return [Hash{Symbol => Object}] `{ok: true, domain:, docs:}`, `docs` the
    #   `Projector::DocsProjector` output; `{ok: false, error:}` if the boot loaded no
    #   bluebook, or `aggregate` names no declared aggregate
    def describe(runtime:, aggregate: nil)
      bluebook = bluebook_for(runtime)
      options  = aggregate ? { aggregate: aggregate_ir!(bluebook, aggregate).hecks_name } : {}

      ok(domain: bluebook.name, docs: Projector.call(:docs, bluebook: bluebook, options: options))
    rescue *refusal_classes => e
      refused(e)
    end

    # Boots a domain and reports whether it wired and, optionally, model-checked cleanly
    # — zoom level three: is the wiring sound at all. Every bind names a
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
    # @param domain [String] the domain directory to boot, relative to `BOOT_ROOT`
    # @param deep [Boolean] true to also run `Bluebook::ModelCheck` past wiring, into
    #   dead lifecycle transitions, unreachable saga states and dispatches to nowhere
    # @return [Hash{Symbol => Object}] `{ok: true, domain:, valid: true}`, plus
    #   `:findings` (one `{kind:, severity:, subject:, message:}` Hash per
    #   `Bluebook::ModelCheck::Finding`) when `deep` is true; `{ok: false, domain:,
    #   valid: false, error:}` naming the raised exception's class and message when the
    #   boot, or the model check, raises anything at all
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

    # Reads every aggregate's full append-only write history, not just the current
    # head — `bin/history`'s own logic, unchanged: an append-only-backed aggregate's
    # `entries`, every operation that ever touched it. An aggregate bound to a
    # non-append-only adapter (Memory, Postgres proper) answers an empty
    # list honestly rather than pretending to a history it never kept.
    #
    # @param runtime [Runtime::Dispatcher] the booted runtime to read
    # @return [Hash{Symbol => Object}] `{ok: true, domain:, history:}`, `history` a Hash
    #   of aggregate storage name to that aggregate's `journal_entries`
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

    # Reads one aggregate's append-only journal, materialized to plain data.
    #
    # @param repository [Object] the aggregate's repository, as `Registry#repository`
    #   resolves it — any adapter's repository object; only one that is also a
    #   `Ports::Persistence::AppendOnly` yields entries
    # @return [Array<Hash{Symbol => Object}>] one `{operation:, id:, state:}` Hash per
    #   journal entry, in the repository's own order; `[]` for a non-append-only
    #   repository
    def journal_entries(repository)
      return [] unless repository.is_a?(Ports::Persistence::AppendOnly)

      repository.entries.map { |entry| { operation: entry.operation, id: entry.id, state: Facade::JsonDoor.materialize(entry.state) } }
    end

    # Runs one `.behaviors` file, or sweeps a directory of them, and reports the results
    # — hand-curated examples of how
    # to use a domain, in domain vocabulary (`docs/guides/behaviors.md`),
    # the survey's own "honest-refusal", generated-example-suite items.
    # `Hecks::Behaviors` boots each test fresh through `Hecks.boot_files`
    # itself — `target:` names a `.behaviors` file or a directory to
    # sweep, never a `runtime:`, the one other method here besides
    # `validate` that takes a path instead.
    #
    # @param target [String] a `.behaviors` file's path, or a directory to sweep,
    #   recursively, for `.behaviors` files
    # @return [Hash{Symbol => Object}] `{ok: true, target:, files:, counts:}`, `files`
    #   one `behaviors_file` Hash per file swept, `counts` the aggregate tally
    #   `Behaviors.summarize` returns
    # @raise [Runtime::NotFound] if `target` names neither an existing file nor directory
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

    # Shapes one `.behaviors` file's own result for the JSON answer.
    #
    # @param result [Behaviors::FileResult] one file's own result, as `Behaviors.run`
    #   returns it
    # @return [Hash{Symbol => Object}] `{path:, parse_error:, runs:}`, `runs` one
    #   `{description:, status:, message:}` Hash per test, `[]` when the file failed to
    #   parse
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
    # @param runtime [Runtime::Dispatcher] the booted runtime, to name the audit log
    # @param limit [Integer, #to_i] the most recent entries to return, at least 1
    # @return [Hash{Symbol => Object}] `{ok: true, domain:, entries:}`, `entries` the
    #   most recent `limit` audit log lines, oldest first, each a Hash with Symbol keys
    def follow(runtime:, limit: 20)
      bluebook = bluebook_for(runtime)
      entries  = log_lines(bluebook.name).last([limit.to_i, 1].max)

      ok(domain: bluebook.name, entries: entries)
    rescue *refusal_classes => e
      refused(e)
    end

    # Reads a domain's own audit log back into plain data.
    #
    # @param domain_name [String, Symbol, nil] the bluebook's name
    # @return [Array<Hash{Symbol => Object}>] one Hash per logged line, in the order
    #   `record!` wrote them; `[]` when the domain has no log file yet
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
    # @param runtime [Runtime::Dispatcher] the booted runtime, to name the audit log
    # @param aggregate [String, Symbol, nil] narrows to one aggregate's own events;
    #   `nil` searches every aggregate this bus has dispatched to
    # @param id [String, nil] narrows to one record's own events; requires `aggregate`
    # @param limit [Integer, #to_i, nil] the most recent matching events to return;
    #   `nil` returns every one found
    # @return [Hash{Symbol => Object}] `{ok: true, domain:, events:}`, `events` one Hash
    #   per event (merging `time:`, `verb:` and `id:` from its logged dispatch onto the
    #   event's own `name:`/`payload:`), oldest first
    # @raise [Runtime::TypeMismatch] if `id` is given without `aggregate`
    # @raise [Runtime::NotFound] if `aggregate` names no declared aggregate
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
    # @param entry [Hash{Symbol => Object}] one logged audit line, as `log_lines` parses it
    # @param fqn [String, nil] the aggregate FQN to narrow to; `nil` matches any
    # @param id [String, nil] the record id to narrow to; `nil` matches any
    # @return [Array<Hash{Symbol => Object}>, nil] `nil` when the entry is not a
    #   successful dispatch carrying events, or does not match `fqn`/`id`; otherwise one
    #   Hash per announced event, each merged with the entry's own `time:`, `verb:` and
    #   `id:`
    def entry_events(entry, fqn, id)
      return unless entry[:tool] == "dispatch" && entry[:ok] && entry[:events]
      return if fqn && !entry[:verb].to_s.start_with?("#{fqn}.")
      return if id && entry[:id] != id

      entry[:events].map { |event| event.merge(time: entry[:time], verb: entry[:verb], id: entry[:id]) }
    end

    # ── shared shape ────────────────────────────────────────────────────

    # Lists every exception class this bus catches and turns into a `{ok: false}`
    # outcome rather than letting it crash a caller.
    #
    # `Runtime::WiringError` belongs here too, alongside the true domain
    # refusals — not because it is one (it's a structural defect, not a
    # rule the caller broke), but because "this domain isn't wired to
    # answer what you're asking" (a `role:`+`actor_id:` caller reaching
    # an authorization port nothing implements, a dry run against a
    # port verb) is exactly the shape this bus promises never crashes
    # through it. `dry_run_outcome` already treats it this way locally;
    # this makes every other caller of `refusal_classes` do the same.
    #
    # @return [Array<Class>] `Runtime::NotFound`, `Runtime::TypeMismatch`,
    #   `Runtime::WiringError`, plus every class in `Runtime::DOMAIN_REFUSALS`
    def refusal_classes = [Runtime::NotFound, Runtime::TypeMismatch, Runtime::WiringError, *Runtime::DOMAIN_REFUSALS]

    # Builds a successful outcome Hash.
    #
    # @param fields [Hash{Symbol => Object}] merged in alongside `ok: true`
    # @return [Hash{Symbol => Object}] `{ok: true}` merged with `fields`
    def ok(**fields) = { ok: true }.merge(fields)

    # Builds a refused outcome Hash, an honest refusal rather than a crash — the
    # survey's own item #9: "an
    # explicit, structured refusal a caller can act on" rather than a
    # stack trace an agent has to parse to find the one line that
    # mattered. The domain's own refusal text travels verbatim
    # (`RefusalWording` already renders every one of these to be read),
    # this only wraps it consistently.
    #
    # @param error [StandardError] the caught refusal
    # @param summary [String, nil] the call's own summary, carried into the outcome
    # @return [Hash{Symbol => Object}] `{ok: false, summary:, error:}`, `error` the
    #   refusal's own message, verbatim
    def refused(error, summary: nil) = { ok: false, summary: summary, error: error.message }
  end
end
