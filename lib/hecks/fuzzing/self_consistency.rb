require "json"
require "tmpdir"
require "open3"
require_relative "../adapters/driven/heki"

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
          value_object_round_trip: check_value_object_round_trip(history) }
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
