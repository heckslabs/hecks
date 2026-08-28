require_relative "../saga_pending_dispatch"

module Hecks
  module Runtime
    class Registry
      # SAGA PERSISTENCE — no new DSL verb, no new world setting.
      # Whatever adapter a domain's own aggregates already use for
      # durability, its sagas use the same one, automatically: three
      # OPTIONAL adapter methods (`save_saga`/`delete_saga`/`each_saga`),
      # `respond_to?`-checked the same way `Ports::Persistence::AppendOnly`
      # already treats an adapter's own optional methods
      # (`find`/`all`/`count`/`reset!`/`events`/`record_event`).
      module SagaPersistence
        # Resolved and memoized per domain — the FIRST real aggregate
        # declared in the domain's own bluebook is the resolution
        # anchor. `Ports::Persistence::BindingPolicy.resolve` for that
        # aggregate already falls back to a domain-level default bind
        # (§0's `Hecksagon#bind_for`) before falling back to Memory, so
        # this needs no separate "was a default declared" branch of its
        # own — whatever adapter that anchor resolves to already IS the
        # domain's own default in the normal case (every aggregate
        # shares one adapter), and is the honest, documented fallback
        # for the rarer domain genuinely split across more than one
        # local adapter with no default declared.
        #
        # GENUINELY LAZY, GENUINELY POST-BOOT — unlike `rehydrate_sagas!`
        # below (boot-only), this is called from live dispatch
        # (`SagaInterpreter#checkpoint`/`#end_saga`, on every saga
        # transition), so the FIRST call for a given domain can come from
        # any dispatching thread, not just the boot thread. `@saga_persistence`
        # itself is a plain Hash stood up once in `Registry#initialize` (no
        # race on the container), but `resolve_saga_persistence` is real work
        # (a `BindingPolicy.resolve` plus a lazy `repository` build) whose
        # RESULT — the actual adapter instance a domain's sagas persist
        # through — must be the SAME object for every caller: two threads
        # racing the first lookup and each building their own adapter would
        # silently split one domain's saga writes across two adapter
        # instances (worse than `Dispatcher#reaction_depth`'s M20 — that bug
        # corrupted a counter; this one can corrupt WHICH STORE a saga's
        # state lands in). Double-checked locking against a DEDICATED mutex
        # — never `@saga_mutex` — see `Registry#initialize`'s own comment for
        # why reusing that one would deadlock.
        def saga_persistence(domain)
          key = domain.to_s
          @saga_persistence[key] || @saga_persistence_mutex.synchronize { @saga_persistence[key] ||= resolve_saga_persistence(key) }
        end

        # WALKS EVERY LOADED DOMAIN, repopulating `saga_instances` from
        # whatever `saga_persistence(domain)` resolves to — a real store
        # for a domain whose adapter answers the capability, `each_saga`
        # yielding real rows; `NULL_SAGA_STORE`'s own `each_saga` for
        # everything else, which never yields at all, so this needs no
        # `respond_to?` branch of its own — the SAME reason every other
        # call site in this capability never needs one. Called once at
        # boot (`Loader.boot`, between `verify!` and dispatcher
        # construction) — a process that's been running has no reason to
        # re-walk its own already-current `saga_instances`.
        #
        # BOOT-TIME-ONLY (OR ITS TEST-RUNNER EQUIVALENT) — this method's
        # only callers are `Loader.run_boot_gates!` (single-threaded, before
        # `dispatcher_for` ever exists) and `Registry#reset_runtime_state!`
        # (single-threaded test runner — see that method's own comment).
        # Never called from live dispatch, so `@saga_instances` mutation
        # here has no concurrent caller to race, unlike its OTHER two write
        # points inside `@saga_mutex.synchronize` blocks (`saga_interpreter.
        # rb`), which genuinely do and are guarded accordingly.
        # rubocop:disable-next Hecks/ThreadSharedIvarMutation
        def rehydrate_sagas!
          @hecksagons.each_key do |domain|
            saga_persistence(domain).each_saga do |process_manager, correlation, state, memory, completed_compensations = []|
              pending = memory.delete(SAGA_PENDING_DISPATCH_KEY)
              @saga_instances[process_manager][correlation] =
                { state: state, memory: memory, completed_compensations: completed_compensations || [] }
              warn_stalled_saga(domain, process_manager, correlation, state, pending) if pending
            end
          end
          self
        end

        private

        # THE OTHER HALF OF THE OUTBOX-SHAPED FIX (see saga_pending_
        # dispatch.rb) — `SAGA_PENDING_DISPATCH_KEY`, if the crashed
        # process left it standing, means the row's own `state` was
        # checkpointed but the dispatch cascade that justifies it may
        # never have run. Stripped out of `memory` before it becomes
        # this instance's LIVE `:memory` (so nothing downstream — a
        # `given`, a `with:` mapping, the fuzzer — ever sees it), and
        # surfaced loudly instead: a WARNING plus a `saga_log` entry,
        # never an automatic redrive (see saga_pending_dispatch.rb for
        # why redriving without idempotent delivery would be worse than
        # the stall). This is real, durable crash-recovery VISIBILITY —
        # still not the reconciliation itself, which stays a human's
        # call until hecks has idempotent redelivery to make it safe.
        # rubocop:disable-next Hecks/ThreadSharedIvarMutation -- same
        # justification as `rehydrate_sagas!`'s own disable comment
        # above: this method's ONLY caller is that boot-time-only walk,
        # never live dispatch, so `@saga_log` has no concurrent writer
        # to race here.
        def warn_stalled_saga(domain, process_manager, correlation, state, pending)
          # `.transform_keys(&:to_sym)` — Heki's own `each_saga` only
          # symbolizes `memory`'s TOP-level keys (`SagaStore#each_saga`'s
          # own `transform_keys`, one level deep); a value NESTED under
          # one of those keys, like this marker, comes back with plain
          # string keys from Heki specifically, symbol keys already from
          # Postgres/SQLite/D1's own `symbolize_names: true` parse. Normalizing
          # here, once, is simpler than teaching every adapter's own
          # shallow/deep parsing convention about this one reserved key.
          pending    = pending.transform_keys(&:to_sym)
          dispatches = Array(pending[:dispatches]).join(", ")
          warn "[hecks] #{domain} rehydrated #{process_manager} instance #{correlation.inspect} in state " \
               "#{state.inspect} with a dispatch left pending from before the last crash/restart — " \
               "#{dispatches} (on #{pending[:on].inspect}, #{pending[:from].inspect} -> #{pending[:to].inspect}) " \
               "may or may not have actually run. hecks does not auto-redrive a pending saga dispatch (that " \
               "needs idempotent delivery, which this pipeline doesn't have yet); reconcile this instance by hand."
          @saga_log << { process_manager: process_manager, instance: correlation, rehydrated_stalled: true,
                         state: state, pending: pending }
        end

        def resolve_saga_persistence(domain)
          anchor = hecksagon(domain) && bluebook(domain)&.aggregates&.first
          return Ports::Persistence::NULL_SAGA_STORE unless anchor

          bind = Ports::Persistence::BindingPolicy.resolve(self, domain, anchor)
          return Ports::Persistence::NULL_SAGA_STORE if adapter_class(bind.adapter) <= Ports::Persistence::RemoteRuntime

          adapter = repository(domain, anchor).adapter
          adapter.respond_to?(:save_saga) ? adapter : Ports::Persistence::NULL_SAGA_STORE
        rescue WiringError
          # A domain not cleanly wired for its own anchor aggregate's
          # persistence (a test fixture binding only the aggregates it
          # exercises, say) degrades saga persistence to the same no-op
          # default an unbound domain gets — never raises out of a
          # dispatch that would otherwise have succeeded. Matches this
          # capability's own framing throughout: automatic wherever it's
          # cleanly supported, silently absent wherever it isn't.
          Ports::Persistence::NULL_SAGA_STORE
        end
      end
    end
  end
end
