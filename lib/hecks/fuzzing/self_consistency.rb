require "json"
require "tmpdir"
require "open3"
require_relative "../adapters/driven/heki"
require_relative "../runtime/saga_interpreter"

module Hecks
  module Fuzzing
    # A SECOND COMPARISON AXIS — every OTHER check this practice runs is
    # DIFFERENTIAL: Ruby vs the compiled Rust conformance binary, on the
    # same generated sequence (`bin/qa_sweep`'s own `diff_ruby_vs_rust`,
    # `Properties.check`). Differential comparison structurally cannot
    # catch a bug where both engines are wrong the SAME way, or where a
    # single engine is self-inconsistent with nothing to differentially
    # compare it against. This module asks a DIFFERENT question of ONE
    # engine at a time: does it agree with ITSELF?
    #
    # THREE CHECKS, run on the SAME already-generated sequence and its
    # resulting live state — no second fuzzing pass, no re-dispatch
    # through the command layer:
    #
    #   1. `check_rehydration`   — does reloading an aggregate from its
    #      own durable journal reproduce exactly the state a live dispatch
    #      already produced?
    #   2. `check_idempotency`   — does replaying that SAME journal a
    #      second time change anything? (a variant of #1, but a different
    #      failure mode: no leaked state between applications, not just
    #      "cold load works once.")
    #   3. `check_value_object_round_trip` — does every value object the
    #      sequence actually built survive `to_json` then rebuilt back?
    #
    # THE REHYDRATION PATH, FOUND, NOT GUESSED. hecks is not event-sourced
    # at the aggregate level — there is no `AccountOpened`-shaped log a
    # `CommandInterpreter` folds to rebuild state. What there IS, real and
    # already shipping, is `Ports::Persistence::AppendOnly` (lib/hecks/
    # ports/persistence/append_only.rb): every adapter accepts the same
    # `Entry` stream (`operation`, `id`, the FULL state after that
    # command — not a delta) and answers `#entries`; `#recover!` — "an
    # append is durable before a projection is attempted; replaying the
    # log restores a snapshot/table after a crash in that small window" —
    # is called on EVERY repository this runtime ever builds
    # (`RepositoryFactory.build`'s own `recover: true` default). That IS
    # the production cold-rehydration path. Reusing `#recover!` directly
    # against the LIVE adapter would prove nothing, though: `Fuzzing::
    # Replay` runs against `Adapters::Memory` (`IsolatedBoot`'s own
    # default), and Memory's own `Entry#state` is a SHALLOW `instance.
    # state.dup` — the exact same `Runtime::Value` objects a command
    # produced ride along unchanged, so folding them straight back through
    # Memory's own `#project` is a tautology that can never fail (`Value#
    # for_attribute`'s own `value.is_a?(self) && value.type_name == ...`
    # branch passes an already-typed value straight through, no
    # rebuilding at all).
    #
    # So `cold_read`, below, feeds the SAME entries through `Adapters::
    # Heki` instead — a REAL, already-shipped, disk-backed adapter
    # (examples/banking's own `persisted_by("Heki")`), in a throwaway
    # directory. Writing forces every value through `JSON.generate`
    # (Heki's own journal line, its own compressed snapshot); reading
    # back through a FRESH `Heki` instance (unmemoized `@store`) forces
    # `read_snapshot`/`replay_journal` — real `JSON.parse`, real
    # `Zlib::Inflate`, real bytes off a real filesystem — which is what
    # makes `Instance.hydrate_with_defaults` → `Value.hydrate` →
    # `Value.for_attribute` actually REBUILD every value object from raw
    # data via `Value.build`, the same coercion/validation path a real
    # restart takes, rather than pass the live object through unchanged.
    # This is the exact mechanism `AppendOnly#recover!` names in its own
    # comment ("restores a snapshot/table after a crash"), just exercised
    # against the one adapter whose own `#entries` actually forces the
    # JSON boundary Memory's does not.
    module SelfConsistency
      module_function

      # THE WHOLE PASS — called once, with the runtime STILL LIVE (inside
      # `Replay.call`'s own `IsolatedBoot.call` block, before the tmp
      # directory and its adapters go out of scope) and the `history`
      # `Replay.call` is about to return. Nothing here boots a second
      # runtime or dispatches a single command; every check below reads
      # data this ONE replay already produced. Just the three checks
      # below, run and collected — kept as three independently callable
      # methods (not fused into one shared fold) so a spec proving one
      # check can fire never has to reason about the other two.
      def check(runtime, history)
        { rehydration: check_rehydration(runtime), idempotency: check_idempotency(runtime),
          value_object_round_trip: check_value_object_round_trip(history),
          saga_rehydration: check_saga_rehydration(runtime, history),
          saga_redelivery_idempotency: check_saga_idempotency(runtime, history) }
      end

      # CHECK 1 — REHYDRATE-FROM-JOURNAL == LIVE STATE.
      def check_rehydration(runtime)
        each_touched_repository(runtime).filter_map do |domain_name, aggregate, repository, entries|
          live = snapshot(repository)
          Dir.mktmpdir("hecks-self-consistency") do |tmp|
            writer     = Adapters::Heki.new(aggregate: aggregate, root: tmp)
            rehydrated = fold!(writer, tmp, aggregate, entries)
            next if rehydrated == live

            { field: "rehydration", domain: domain_name, aggregate: aggregate.hecks_name,
              live: live, rehydrated: rehydrated }
          end
        end
      end

      # CHECK 2 — REPLAY IDEMPOTENCY: folding the SAME entries into the
      # SAME durable store a second time must change nothing. A variant
      # of check 1, worth stating separately — this catches a
      # replay-specific bug (leaked state between applications, a
      # double-applied effect) that a single, one-shot cold read could
      # never see, even one that already agrees with live state.
      def check_idempotency(runtime)
        each_touched_repository(runtime).filter_map do |domain_name, aggregate, repository, entries|
          Dir.mktmpdir("hecks-self-consistency") do |tmp|
            writer = Adapters::Heki.new(aggregate: aggregate, root: tmp)
            once   = fold!(writer, tmp, aggregate, entries)
            twice  = fold!(writer, tmp, aggregate, entries)
            next if once == twice

            { field: "idempotency", domain: domain_name, aggregate: aggregate.hecks_name,
              once: once, twice: twice }
          end
        end
      end

      # CHECK 3 — every `Runtime::Value` the sequence actually built
      # (walked out of the replay's own `instances`/`events`/`queries`,
      # never a hand-picked example), round-tripped through the REAL
      # serialize/deserialize pair: `Value#to_json` (JSON.generate(to_h),
      # value.rb) out, `Value.build` (value/coercion.rb — the same
      # constructor a command argument's own raw JSON goes through) back
      # in. There is no class-level `VO.from_json` in this codebase (that
      # spelling is Rust's — rust/src/exemplar/json.rs's generated
      # `from_json` per closed set/value object); `Value.build` is the
      # actual Ruby door a raw, untyped Hash becomes a validated,
      # admitted, invariant-checked value object through.
      # `aggregate:` THREADED ALONGSIDE EVERY VALUE FOUND, NOT DROPPED —
      # `Value.build(value_object, fields, aggregate)`'s third argument is
      # what lets `normalize_composite_fields` resolve a NESTED composite
      # field's own type by name (`value_object_for(aggregate, type)`).
      # Building with `aggregate: nil` (this method's first version, live-
      # tested against `examples/pizzas` while this was being written)
      # silently skips that step entirely — `Pizza`'s own `price_cents`/
      # `size` fields round-tripped back as bare, STRING-keyed Hashes
      # instead of rebuilt `Money`/`PizzaSize` value objects, a false
      # POSITIVE this check would have reported as a real bug on every
      # single sweep. Resolved from `history[:instances]`' own key
      # (`"Domain::Aggregate#id"`, `Replay#snapshot_instances`) and
      # `history[:events]`' own `event[:aggregate]` (`"Domain::Aggregate"`,
      # domain-qualified) against `history[:bluebooks]` — the exact same
      # loaded chapter map every other replay-time check already reads
      # off `history` rather than a second lookup. `history[:queries]`'
      # own rows have no single owning aggregate reliably named on the
      # entry itself (a cross-aggregate read model, a `for_each` target),
      # so they are left OUT of this walk rather than risk the same false
      # positive `nil` already produced once — `instances` and `events`
      # alone already reach every value object a generated sequence
      # actually persisted or announced.
      def check_value_object_round_trip(history)
        bluebooks = history[:bluebooks] || {}
        seen = {}.compare_by_identity
        found = []

        history[:instances].each do |key, state|
          domain_name, aggregate_name = key.to_s.split("#", 2).first.to_s.split("::", 2)
          aggregate = bluebooks[domain_name]&.aggregate(aggregate_name)
          walk_value_objects(state, found, seen, aggregate)
        end

        history[:events].each do |event|
          domain_name, aggregate_name = event[:aggregate].to_s.split("::", 2)
          aggregate = bluebooks[domain_name]&.aggregate(aggregate_name)
          walk_value_objects(event[:payload], found, seen, aggregate)
        end

        found.filter_map do |value, aggregate|
          begin
            rebuilt = Runtime::Value.build(value.value_object, JSON.parse(value.to_json), aggregate)
          rescue StandardError => e
            next { field: "value_object_round_trip", type: value.type_name, original: value.to_h,
                   error: "#{e.class}: #{e.message}" }
          end

          next if rebuilt == value

          { field: "value_object_round_trip", type: value.type_name, original: value.to_h,
            rehydrated: rebuilt.to_h }
        end
      end

      # CHECK 4 — SAGA COLD-REHYDRATION (ANGLE-10). Checks 1/2 above cold-
      # read an AGGREGATE's own journal through Heki; nothing in this file
      # ever exercised the OTHER durable store `SagaInterpreter#checkpoint`
      # writes through — `Ports::Persistence::NullSagaStore`'s own header
      # calls Heki's `SagaStore` (`adapters/driven/heki/saga_store.rb`) the
      # OPTIONAL saga-persistence capability, and it is real and already
      # shipping, just never fuzzed: `Registry#rehydrate_sagas!` — the
      # production "process just restarted" path — folds exactly what
      # `each_saga` yields back into `@saga_instances`, and until now
      # nothing ever proved that round trip faithful for a sequence this
      # practice actually generated. `BUG#6`/`#9`/`#10` all came out of
      # this exact interpreter, which is why this checks it specifically
      # rather than folding it into checks 1/2's own aggregate walk.
      #
      # `history[:saga_instances]` (`replay.rb`'s own `saga_instances`
      # local, built once at the very end of a replay) is the SAME
      # materialized `{pm_name => {correlation => {state:, memory:}}}`
      # shape `SagaInterpreter#checkpoint` itself hands a real adapter —
      # read from `history`, not re-derived from the (by-now-live, already
      # mutated by whatever `check_saga_idempotency` ran first, see that
      # method's own header) `runtime.registry.saga_instances`. Written
      # through a REAL `Adapters::Heki` (a throwaway tmpdir, one per
      # process manager so two process managers with correlations that
      # happen to collide as strings never share a store), read back
      # through a FRESH instance (unmemoized `@store`/`@saga_store`, same
      # reason `fold!` above uses one) — forcing the identical
      # `JSON.generate`/`JSON.parse` boundary a real crash-then-restart
      # takes, not a live-object pass-through.
      #
      # ONE FINDING PER (domain, process manager) — every correlation this
      # process manager's own `history[:saga_instances]` entry holds,
      # compared as a whole Hash — the same aggregate-granularity (not
      # per-record) `check_rehydration` already reports at.
      #
      # `completed_compensations` is DELIBERATELY OUT OF SCOPE — `history[
      # :saga_instances]` never captures it (`replay.rb`'s own comment:
      # only `state`/`memory` are threaded through, since a saga's
      # in-flight compensation ledger is a fact about a leg still running,
      # not the settled snapshot this history exists to describe), so
      # there is no ground truth to compare it against here. Written as an
      # empty array on the way in and never read back on the way out.
      def check_saga_rehydration(runtime, history)
        saga_instances = history[:saga_instances] || {}
        each_domain_process_manager(runtime).filter_map do |domain_name, process_manager|
          persisted = saga_instances[process_manager.name]
          next if persisted.nil? || persisted.empty?

          anchor = runtime.registry.bluebook(domain_name).aggregates.first
          next unless anchor

          Dir.mktmpdir("hecks-self-consistency-saga") do |tmp|
            writer = Adapters::Heki.new(aggregate: anchor, root: tmp, settings: { domain: domain_name })
            persisted.each do |correlation, saga|
              writer.save_saga(process_manager: process_manager.name, correlation: correlation.to_s,
                               state: saga[:state], memory: saga[:memory], completed_compensations: [])
            end

            live       = normalize_saga_rows(persisted)
            rehydrated = cold_read_saga_rows(anchor, tmp, domain_name)
            next if rehydrated == live

            { field: "saga_rehydration", domain: domain_name, process_manager: process_manager.name,
              live: live, rehydrated: rehydrated }
          end
        end
      end

      # CHECK 5 — REDELIVERY IDEMPOTENCY OF THE CHECKPOINT-THEN-LOAD PATH.
      # `check_saga_rehydration` above proves cold-reading a checkpoint
      # reproduces the same DATA; this proves the OTHER half of a real
      # crash/restart — a message an at-least-once delivery mechanism (an
      # outbox redrive, a queue redelivery) hands the rehydrated saga a
      # SECOND time — does not silently re-advance it. There is no flag
      # for this in production (`SagaInterpreter#unwind`'s own comment:
      # "the check is the guard") — the (event, current state) lookup
      # `handler_for` performs is the ENTIRE mechanism, and it has never
      # been exercised against a state this practice loaded from cold
      # storage rather than one still sitting in a live process's memory.
      #
      # ONE (PROCESS MANAGER, CORRELATION) TESTED, using a fresh
      # `Runtime::SagaInterpreter` sharing `runtime`'s own `registry` and
      # `door: runtime` — the identical two objects the DISPATCHER'S own
      # `@sagas` was built from (`dispatcher.rb`'s own `SagaInterpreter.
      # new(registry, door: self)`) — not a hand-rolled re-implementation
      # of `advance_saga`'s own state-guard. `only: process_manager` scopes
      # the redelivery to exactly the one procedure under test, the same
      # keyword the outbox relay already uses to run one consumer alone
      # (`Runtime::Outbox::Relay#run_consumer`).
      #
      # WHICH EVENT TO REDELIVER — `runtime.registry.saga_log`'s own last
      # `advanced: true` row for this (process manager, correlation) names
      # the event BY NAME ONLY; the REAL `Runtime::Event` object (payload,
      # aggregate, id, `correlation` — everything `saga_correlation`/
      # `dispatch_args` actually read) lives in `runtime.events`, still
      # live for exactly this reason (this file's own header: "runtime IS
      # STILL LIVE HERE"). Matched back by NAME plus `saga_correlation`
      # itself (`Runtime::SagaInterpreter::Correlation`, `private`) —
      # reused via `send` rather than reproduced, because reproducing its
      # three-tier fallback (a dotted payload field, a stamped passthrough,
      # a self-identifying `event.id`) here would be exactly the
      # hand-rolled approximation this file was told not to build. A
      # `:refused`-driven (compensating) transition is skipped outright —
      # its own `saga_log` row's `on:` is the synthetic `REFUSED` trigger
      # name, never a real domain event, so there is nothing to redeliver.
      #
      # SIMULATING "JUST RESTARTED" — the live registry's own in-memory
      # `saga_instances[pm][correlation]` slot is overwritten, IN PLACE,
      # with whatever a cold Heki read of the SAME checkpoint answers
      # (exactly what `Registry#rehydrate_sagas!` does for real on every
      # boot), the redelivery is driven through the real interpreter, and
      # the slot is put back — `ensure`d — once this correlation's own
      # check is done. Safe ONLY because `check`/`Replay.call` run this,
      # synchronously, single-threaded, as the very last thing before
      # `runtime` and its whole tmp directory go out of scope for good;
      # nothing downstream of this method ever reads the LIVE registry
      # again (`check_saga_rehydration`, `check_rehydration`, `check_
      # idempotency`, `check_value_object_round_trip` all read `history`'s
      # own frozen snapshot instead, never `runtime.registry` — so calling
      # order relative to this method's own mutation doesn't matter).
      #
      # THE ASSERTION IS ABOUT `state`/`memory`, NOT "did a dispatch fire"
      # — a leg whose own `from:`/`to:` are the SAME state (every existing
      # saga's own starts_on self-transition, `waybill.bluebook`'s own leg
      # 1/2) is EXPECTED to re-run on redelivery with no visible state
      # change at all; that is a property of the declared handler graph,
      # not a rehydration defect, and asserting against it here would
      # manufacture a false positive on every saga this corpus has. A
      # correlation whose current state has no declared handler at all for
      # the redelivered event name (the ordinary, expected case once a
      # saga has moved past the leg that produced its own current
      # checkpoint) is exactly what this proves stays put.
      def check_saga_idempotency(runtime, history)
        saga_instances = history[:saga_instances] || {}
        interpreter    = Runtime::SagaInterpreter.new(runtime.registry, door: runtime)

        each_domain_process_manager(runtime).flat_map do |domain_name, process_manager|
          persisted = saga_instances[process_manager.name]
          next [] if persisted.nil? || persisted.empty?

          anchor = runtime.registry.bluebook(domain_name).aggregates.first
          next [] unless anchor

          persisted.filter_map do |correlation, saga|
            redelivery = last_advancing_event(runtime, interpreter, process_manager, correlation)
            next unless redelivery

            check_one_saga_redelivery(runtime, interpreter, domain_name, process_manager, anchor,
                                      correlation, saga, redelivery)
          end
        end
      end

      # ── Rust-side self-consistency ───────────────────────────────────
      #
      # THE COMPILED BINARY'S OWN REHYDRATION DOOR, ALREADY SHIPPING —
      # `kernel/cli.rs`'s `run` accepts an OPTIONAL top-level `"seed"` key
      # ("the exact 'Domain::Aggregate#id' -> state shape THIS run's own
      # 'instances' output already produces... lets a HOST seed prior
      # state back in instead of replaying `steps` from scratch every
      # invocation"). `Store::from_seed`/`Store::instances` are that
      # mechanism's own two halves — `rust/host` (docs/implemented/
      # decisions/0012) depends on them being true inverses for real,
      # today. `rust_seed_round_trip` exercises exactly that: a SECOND,
      # independent invocation of the SAME binary, `"steps": []` (nothing
      # new dispatched — this is rehydration, not re-dispatch), seeded
      # with whatever `"instances"` a PRIOR invocation already produced.
      # `differ` (unused, kept in the signature — see below) is a
      # `RustConformanceHelpers`-including instance (`bin/qa_sweep`'s own
      # `Differ`), the same argument `check_rust_rehydration`/`check_
      # rust_idempotency` already take from their own callers; kept here
      # rather than dropped from all three signatures at once so a
      # future differential-style reduction has a door already open,
      # without this module ever `require`ing `spec/support/` itself.
      # NEITHER `strip_emitted_flags!` NOR ANY OTHER DIFFERENTIAL-ONLY
      # REDUCTION RUNS HERE — that reduction exists so a Rust-only
      # bookkeeping field (`emitted_<event>`, docs/decisions/0049) never
      # counts against Ruby, which has no equivalent field to agree with
      # at all (`RustConformanceHelpers#strip_emitted_flags!`'s own
      # comment). This check has no Ruby side to spare — it is asking the
      # Rust binary whether it agrees with ITSELF, so `emitted_*` fields
      # are exactly as real a fact to compare as any other. Stripping them
      # here (an earlier version of this method did) silently deleted
      # them from the RETURNED seed-round-trip result while leaving them
      # present on the ORIGINAL `seed_instances` a caller passes in — an
      # asymmetric comparison that reported EVERY record carrying one as
      # a rehydration divergence, unconditionally, on every domain that
      # has one at all. Found live against `examples/banking`
      # (`Banking::Account`'s own `corrects` reaction) while this
      # integration was being written, by comparing this method's own
      # answer against the compiled binary's RAW stdout for the identical
      # seed call: the raw round trip preserved `emitted_fee_applied`
      # correctly; only THIS method's own stripping dropped it. `spec/
      # self_consistency_rust_spec.rb`'s own "banking" example pins the
      # regression against a real domain going forward.
      def rust_seed_round_trip(binary, _differ, seed_instances)
        stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => [], "seed" => seed_instances }))
        return { "__self_consistency_error__" => "rust binary exited #{status.exitstatus}: #{stdout}" } \
          unless status.success?

        parsed = JSON.parse(stdout)
        return { "__self_consistency_error__" => parsed["error"] } if parsed["error"]

        parsed["instances"]
      end

      # CHECK 1, RUST SIDE — seeding a fresh invocation with a PRIOR
      # invocation's own live `"instances"` must reproduce that same
      # state, unchanged. `live_instances` is `rust_output["instances"]`
      # — the exact same value `bin/qa_sweep`'s own differential compare
      # already diffed against Ruby, reused here rather than re-derived.
      def check_rust_rehydration(binary, differ, live_instances)
        rehydrated = rust_seed_round_trip(binary, differ, live_instances)
        return [] if rehydrated == live_instances

        [{ field: "rust_rehydration", live: live_instances, rehydrated: rehydrated }]
      end

      # CHECK 2, RUST SIDE — seeding with what a first seed round trip
      # already produced, a SECOND time, must not drift any further. The
      # same "replay it again, byte for byte" claim `check_idempotency`
      # proves for Ruby, aimed at the one rehydration door this compiled
      # binary actually has.
      def check_rust_idempotency(binary, differ, live_instances)
        once  = rust_seed_round_trip(binary, differ, live_instances)
        twice = rust_seed_round_trip(binary, differ, once)
        return [] if once == twice

        [{ field: "rust_idempotency", once: once, twice: twice }]
      end

      # ── shared plumbing ─────────────────────────────────────────────

      # EVERY [domain, aggregate] PAIR THIS SEQUENCE ACTUALLY WROTE TO —
      # an aggregate with an empty `#entries` never had anything dispatch
      # against it this run, so there is nothing to rehydrate and no
      # finding a "clean, nothing touched" report would mean anything
      # for. Mirrors `Replay#snapshot_instances`' own
      # `bluebooks.each { aggregates.each { repository(...) } }` walk.
      def each_touched_repository(runtime)
        found = []
        runtime.registry.bluebooks.each do |domain_name, bluebook|
          bluebook.aggregates.each do |aggregate|
            repository = runtime.registry.repository(domain_name, aggregate)
            entries    = repository.entries
            next if entries.empty?

            found << [domain_name, aggregate, repository, entries]
          end
        end
        found
      end

      def snapshot(repository)
        repository.all.to_h { |record| [record.id.to_s, Runtime::Value.materialize(record.state)] }
      end

      # EVERY [domain, process manager] PAIR ANY LOADED BLUEBOOK DECLARES —
      # regardless of whether this replay's own `history[:saga_instances]`
      # ever touched it (mirrors `each_touched_repository`'s own walk one
      # level up; the "did anything actually persist" filter lives in each
      # check's own caller, same as that method's `entries.empty?` guard).
      # An empty return here IS the "domain declares no process manager"
      # skip `check_saga_rehydration`/`check_saga_idempotency` both need —
      # `filter_map`/`flat_map` over an empty Array already answers `[]`,
      # identical to "ran and found nothing," which is deliberate: neither
      # check has a positive "passed" artifact to report either way (see
      # this file's own header on why silence is never a claimed pass).
      def each_domain_process_manager(runtime)
        found = []
        runtime.registry.bluebooks.each do |domain_name, bluebook|
          bluebook.process_managers.each { |pm| found << [domain_name, pm] }
        end
        found
      end

      # THE LIVE-SIDE GROUND TRUTH, key-shape-normalized (see `deep_
      # stringify_keys`'s own comment) so it compares fairly against a
      # real Heki round trip's own shallow-symbolize convention.
      def normalize_saga_rows(persisted)
        persisted.each_with_object({}) do |(correlation, saga), rows|
          rows[correlation.to_s] = { state: saga[:state], memory: deep_stringify_keys(saga[:memory]) }
        end
      end

      # A FRESH `Adapters::Heki` AT THE SAME `tmp`/`domain` — unmemoized
      # `@store`/`@saga_store`, so `#each_saga` is forced back through
      # `read_snapshot`/`replay_journal`, real bytes off real disk, not
      # whatever the writer that just wrote them still holds in its own
      # process memory (the same reason `fold!`, above, opens a second
      # `Adapters::Heki` instance rather than reading its own writer back).
      def cold_read_saga_rows(anchor, tmp, domain_name)
        reader = Adapters::Heki.new(aggregate: anchor, root: tmp, settings: { domain: domain_name })
        reader.each_saga.with_object({}) do |(_pm, correlation, state, memory, _completed), rows|
          rows[correlation] = { state: state, memory: deep_stringify_keys(memory) }
        end
      end

      # `SagaStore#each_saga` ONLY EVER SYMBOLIZES `memory`'S OWN TOP-LEVEL
      # KEYS (`heki/saga_store.rb`'s own `each_saga`, one level deep) —
      # `Registry::SagaPersistence#warn_stalled_saga` already documents
      # this exact asymmetry for the one reserved key production code
      # cares about (`SAGA_PENDING_DISPATCH_KEY`). A NESTED composite
      # memory field (any saga whose starting event carries a value
      # object, which is most of them — `waybill.bluebook`'s own
      # `ConsignmentRequested` alone has three) comes back with STRING
      # keys at every level BELOW the top, while `history[:saga_instances]`
      # 's own `Runtime::Value.materialize` call produces SYMBOL keys
      # throughout. That asymmetry is Heki's own documented, accepted
      # storage convention — an "opaque, adapter-agnostic JSON blob"
      # (`SagaInterpreter#checkpoint`'s own comment), never a typed
      # rebuild the way an AGGREGATE's own composite fields get on cold
      # read (this file's own header: there is no VO schema to rebuild
      # against for a saga's memory blob at all) — not a rehydration
      # defect this check exists to find. Recursively re-stringifying
      # BOTH sides before comparing is what tells that KNOWN, accepted
      # shape difference apart from an ACTUAL data-loss bug (a dropped
      # key, a changed value, a missing field) — exactly the kind (b)'s
      # own seeded fixture in `spec/fuzzing/self_consistency_saga_spec.rb`
      # proves this still catches.
      def deep_stringify_keys(value)
        case value
        when Hash  then value.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify_keys(v) }
        when Array then value.map { |item| deep_stringify_keys(item) }
        else value
        end
      end

      # THE REAL, ALREADY-ANNOUNCED EVENT this correlation's CURRENT
      # checkpoint came from — walked back out of `runtime.registry.
      # saga_log`'s own `advanced: true` rows (newest first), skipping the
      # synthetic `REFUSED` trigger (`Runtime::SagaInterpreter::REFUSED`
      # — a compensating transition's own log entry names that, never a
      # real domain event; there is nothing in `runtime.events` to
      # redeliver for it). `nil` when no real advancing event exists at
      # all (a correlation only ever `begin_saga`'d, never advanced) —
      # `check_saga_idempotency`'s own caller skips a `nil` outright,
      # exactly like `each_touched_repository`'s own "nothing to check"
      # skip one level up.
      #
      # `interpreter.send(:saga_correlation, ...)` — `Correlation` is
      # `private`, and reproducing its own three-tier fallback (a dotted
      # payload field, a stamped passthrough, a self-identifying
      # `event.id`) here rather than reusing it would be exactly the
      # "hand-rolled approximation" this check exists to avoid; `send` on
      # an interpreter sharing this SAME `runtime`'s own registry is the
      # real thing, not a copy of it.
      def last_advancing_event(runtime, interpreter, process_manager, correlation)
        entry = runtime.registry.saga_log.reverse_each.find do |row|
          row[:process_manager] == process_manager.name && row[:instance] == correlation &&
            row[:advanced] && row[:on] != Runtime::SagaInterpreter::REFUSED
        end
        return nil unless entry

        runtime.events.reverse_each.find do |event|
          event.name == entry[:on] && interpreter.send(:saga_correlation, process_manager, event) == correlation
        end
      end

      # ONE (process manager, correlation)'s OWN redelivery check — pulled
      # out of `check_saga_idempotency` itself so that method's own
      # `flat_map`/`filter_map` walk stays readable; every local this
      # shares with its caller (`interpreter`, `anchor`) is passed in
      # rather than re-derived.
      def check_one_saga_redelivery(runtime, interpreter, domain_name, process_manager, anchor,
                                    correlation, saga, redelivery)
        Dir.mktmpdir("hecks-self-consistency-saga") do |tmp|
          writer = Adapters::Heki.new(aggregate: anchor, root: tmp, settings: { domain: domain_name })
          writer.save_saga(process_manager: process_manager.name, correlation: correlation.to_s,
                           state: saga[:state], memory: saga[:memory], completed_compensations: [])

          rehydrated = Adapters::Heki.new(aggregate: anchor, root: tmp, settings: { domain: domain_name })
                                     .each_saga.find { |_pm, corr, *| corr == correlation.to_s }
          next unless rehydrated

          _pm, _corr, state, memory, compensations = rehydrated
          before = { state: state, memory: deep_stringify_keys(memory) }

          saga_instances = runtime.registry.saga_instances[process_manager.name]
          original       = saga_instances[correlation]
          begin
            saga_instances[correlation] = { state: state, memory: memory, completed_compensations: compensations || [] }
            interpreter.advance(redelivery, domain_name, only: process_manager)

            after       = saga_instances[correlation]
            after_shape = after && { state: after[:state], memory: deep_stringify_keys(after[:memory]) }
            next if after_shape == before

            { field: "saga_redelivery_idempotency", domain: domain_name, process_manager: process_manager.name,
              correlation: correlation, on: redelivery.name, before: before, after: after_shape }
          ensure
            if original
              saga_instances[correlation] = original
            else
              saga_instances.delete(correlation)
            end
          end
        end
      end

      # ONE FOLD OF `entries` INTO `writer` (a real, already-open `Heki`
      # adapter at `tmp`), THEN A COLD READ BACK through a BRAND NEW `Heki`
      # instance at the SAME path — `@store` on a fresh instance starts
      # unmemoized, so `#all` below is forced through `#read` →
      # `#read_snapshot`/`#replay_journal`, real disk bytes, not whatever
      # `writer` still holds cached in its own process memory. Called
      # TWICE in a row against the SAME `writer` (see `check`/
      # `check_idempotency` above) is exactly "replay the same journal a
      # second time" — `writer` already holds everything the first fold
      # wrote, so a second fold re-applies the identical operations on
      # top, and the two cold reads either agree (idempotent) or don't.
      def fold!(writer, tmp, aggregate, entries)
        entries.each do |entry|
          writer.append(entry)
          writer.project(entry)
        end

        Adapters::Heki.new(aggregate: aggregate, root: tmp).all
                      .to_h { |record| [record.id.to_s, Runtime::Value.materialize(record.state)] }
      end

      # RECURSES THROUGH A `Value`'S OWN FIELDS VIA `#[]`, NOT `#to_h` —
      # `#to_h` already materializes every field (`Value.materialize`),
      # which would hide a nested `Value` from this walk before it ever
      # got here. In practice a value object's OWN composite fields
      # (`Coercion#normalize_composite_fields`) are validated but stored
      # as plain, already-materialized Hashes, not re-wrapped `Value`
      # instances — confirmed live, not assumed — so this recursion finds
      # nothing further past the field it started from FOR TODAY'S
      # coercion pipeline specifically. Kept anyway, not dead code: the
      # generic `Hash`/`Array` branches below reach the exact same nested
      # data through `node[attribute.name]` regardless, and a future
      # change that DOES start wrapping composite fields as real `Value`
      # instances would be walked correctly here with no change needed.
      # `seen` is a `compare_by_identity` Hash: the same INSTANCE can legitimately
      # appear more than once (an aggregate's live state and an event
      # payload both reference the exact same frozen object), and
      # checking it twice would just waste time, never change the
      # answer — identity, not `Value#==`, is the right notion of
      # "already found" here (two DIFFERENT value objects that happen to
      # hold equal fields are still two separate round trips to prove).
      def walk_value_objects(node, found, seen, aggregate)
        case node
        when Runtime::Value
          return if seen[node]

          seen[node] = true
          found << [node, aggregate]
          node.value_object.attributes.each do |attribute|
            walk_value_objects(node[attribute.name], found, seen, aggregate)
          end
        when Hash
          node.each_value { |value| walk_value_objects(value, found, seen, aggregate) }
        when Array
          node.each { |value| walk_value_objects(value, found, seen, aggregate) }
        end
      end
    end
  end
end
