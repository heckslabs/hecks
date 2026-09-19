require "json"
require_relative "replay"
require_relative "nondeterministic"

module Hecks
  module Fuzzing
    # ## The second differential axis
    #
    # bin/qa_sweep's own `diff_ruby_vs_rust`
    # compares two different engines (the Ruby interpreter vs the compiled
    # Rust kernel) against the same persistence (Memory, always — see
    # `SequenceGenerator`'s own header: sequence generation stays
    # Memory-only, and `IsolatedBoot`'s own header explains why every
    # existing fuzz/replay path structurally cannot reach a real Postgres-
    # bound domain's own SQL compilation). This module compares the
    # opposite pairing: the same one Ruby engine, against two different
    # persistences — Memory (the reference, exactly as fast and as
    # deterministic as every other fuzz check) and a real, disposable
    # `PostgresEra` database (the actual SQL compute/rekey/query-pushdown
    # path a Postgres-bound domain's users really hit).
    #
    # `examples/directory` is why this exists at all: the one domain in
    # this corpus with a real `compute`/`rekey` translation edge
    # (docs/prds/02-fuzzer-real-adapters.md's own "What shipped" section
    # names it directly), which no existing fuzz/replay/property check has
    # ever been able to exercise against real PostgresEra SQL — every one
    # of them boots through `IsolatedBoot`, and until `adapter:
    # :postgres_era` existed (isolated_boot.rb's own header), that meant
    # Memory, unconditionally, no matter what `directory.world` itself
    # declares.
    #
    # ## A separate axis, not a replacement
    #
    # Not a replacement for `bin/qa_sweep`'s own Ruby-vs-Rust differential
    # mode — a genuinely separate axis, opt-in (`--persistence-parity`),
    # because this one pays for a real `PG.connect` and real SQL per
    # dispatch where Memory-vs-Rust pays for neither. See `bin/qa_sweep`'s
    # own `--persistence-parity` handling for the seed-count dial that
    # keeps that cost bounded.
    #
    # ## `left:`/`right:`
    #
    # Generalized — originally hardcoded to Memory vs
    # PostgresEra (the only pairing that existed), now any two of
    # `IsolatedBoot`'s own adapter symbols (`:memory`, `:sqlite`,
    # `:postgres`, `:postgres_era`). Defaults preserve the original
    # pairing exactly, so every existing caller (this file's own spec,
    # `bin/qa_sweep`'s `--persistence-parity`) is unchanged. The second
    # pairing this generalization exists for is Memory vs SQLite
    # (`QualityControlDials::ADAPTER_PARITY_PAIRS`, `bin/qa_sweep`'s own
    # `adapter_parity_sqlite` mode) — `:sqlite` is nearly as cheap as
    # Memory itself (`IsolatedBoot#rebind_to_sqlite!`'s own header: an
    # on-disk file, no server, no disposable database/schema lifecycle to
    # own), so that pairing folds straight into the ordinary per-seed
    # loop instead of needing a deferred wave of its own the way
    # PostgresEra does.
    #
    # ## `database:`/`schema:`
    #
    # Required only when `:postgres_era` is one of
    # the two adapters (the caller — today, only `bin/qa_sweep` — owns the
    # disposable database's whole lifecycle: created before the sweep,
    # dropped after — see that script's own comment, and the discipline
    # `IsolatedBoot#rebind_to_postgres_era!` itself refuses to let a
    # caller skip); every other adapter ignores both, same as `Replay.
    # call`/`IsolatedBoot.call` already do for their own `adapter:`.
    module PersistenceParity
      module_function

      # The same six fields `bin/qa_sweep`'s own `diff_ruby_vs_rust`
      # compares (its own comment: "instances, events, refusals, queries,
      # sagas, reactions") — deliberately the identical set, so a report
      # this mode produces reads exactly like the sibling mode's own,
      # differing only in which two things were compared, not in what
      # "found something" means.
      #
      # Simpler normalization than `diff_ruby_vs_rust`, on purpose — that
      # method reduces Rust's own JSON-over-stdout output to "wire
      # precision" and filters known Ruby/Rust structural gaps, because
      # it is comparing two genuinely different engines that are allowed
      # to differ in already-catalogued, understood ways. Both sides here
      # are the same Ruby engine (`Replay.call`, called twice, adapter
      # only) — there is no second engine's own known-gap catalogue to
      # filter against, so any real difference is the finding. Both
      # results still round-trip through `JSON.generate`/`JSON.parse`
      # before comparing, matching `diff_ruby_vs_rust`'s own discipline —
      # not because either side needs a wire-format reduction, but so
      # `Hash#==`/`Array#==` compares plain, JSON-shaped data on both
      # sides identically (a `Runtime::Value`, a `Symbol` key, a `Time`
      # nobody asked for — none of that survives an accidental leak into
      # this comparison unnoticed).
      #
      # @param domain_path [String] path to the domain directory to boot
      # @param steps [Array<Hash>] the step list to replay against both adapters
      # @param left [Symbol] the first adapter to replay against, one of
      #   `IsolatedBoot`'s adapter symbols (`:memory`, `:sqlite`, `:postgres`,
      #   `:postgres_era`)
      # @param right [Symbol] the second adapter to replay against, same set as `left`
      # @param database [String, nil] connection identity for `:postgres_era`; required
      #   when `left` or `right` is `:postgres_era`, ignored otherwise
      # @param schema [String, nil] disposable schema name for `:postgres_era`; required
      #   when `left` or `right` is `:postgres_era`, ignored otherwise
      # @return [Array<Hash>] divergence entries, each `{field: String, left => Object,
      #   right => Object}` — `left`'s and `right`'s own adapter symbols become the
      #   entry's own keys, holding each side's JSON-shaped value for that field; empty
      #   if both sides agree on every field
      def diff(domain_path, steps, left: :memory, right: :postgres_era, database: nil, schema: nil)
        left_result  = Replay.call(domain_path, steps, adapter: left, database: database, schema: schema)
        right_result = Replay.call(domain_path, steps, adapter: right, database: database, schema: schema)

        divergences = []
        divergences.concat(diff_instances(left_result, right_result, left, right))
        divergences.concat(diff_events(left_result, right_result, left, right))
        divergences.concat(diff_refusals(left_result, right_result, left, right))
        divergences.concat(diff_queries(left_result, right_result, left, right))
        divergences.concat(diff_sagas(left_result, right_result, left, right))
        divergences.concat(diff_reactions(left_result, right_result, left, right))
        divergences
      end

      # Round-trips `value` through JSON, the same wire-precision reduction
      # `diff_ruby_vs_rust` uses so `Hash#==`/`Array#==` compares plain,
      # JSON-shaped data on both sides.
      #
      # @param value [Object] any JSON-serializable value from a replay result
      # @return [Object] `value`, JSON-round-tripped: Symbol keys become Strings,
      #   and any non-JSON-native value surfaces as its own JSON form
      def as_json(value) = JSON.parse(JSON.generate(value))

      # Compares both sides' stored instances.
      #
      # @param left_result [Hash] `left`'s replay result, as returned by `Fuzzing::Replay.call`
      # @param right_result [Hash] `right`'s replay result, as returned by `Fuzzing::Replay.call`
      # @param left [Symbol] the adapter `left_result` was replayed against; becomes
      #   this entry's own key
      # @param right [Symbol] the adapter `right_result` was replayed against; becomes
      #   this entry's own key
      # @return [Array<Hash>] one `{field: "instances", left => Object, right => Object}`
      #   entry if the two sides' JSON-shaped instances differ; empty otherwise
      def diff_instances(left_result, right_result, left, right)
        l = as_json(left_result[:instances])
        r = as_json(right_result[:instances])
        return [] if l == r

        [{ field: "instances", left => l, right => r }]
      end

      # Compares both sides' emitted events.
      #
      # @param left_result [Hash] `left`'s replay result, as returned by `Fuzzing::Replay.call`
      # @param right_result [Hash] `right`'s replay result, as returned by `Fuzzing::Replay.call`
      # @param left [Symbol] the adapter `left_result` was replayed against; becomes
      #   this entry's own key
      # @param right [Symbol] the adapter `right_result` was replayed against; becomes
      #   this entry's own key
      # @return [Array<Hash>] one `{field: "events", left => Object, right => Object}`
      #   entry if the two sides' JSON-shaped events differ; empty otherwise
      def diff_events(left_result, right_result, left, right)
        l = as_json(left_result[:events])
        r = as_json(right_result[:events])
        return [] if l == r

        [{ field: "events", left => l, right => r }]
      end

      # Compares both sides' refusals.
      #
      # `verb:`/`kind:` normalized to plain strings the same way
      # `diff_ruby_vs_rust`'s own `ruby_refusals` mapping does — both
      # sides here already answer strings (`Replay#refusal_kind` always
      # returns one), so this is belt-and-suspenders consistency with the
      # sibling mode's own shape, not a real coercion.
      #
      # @param left_result [Hash] `left`'s replay result, as returned by `Fuzzing::Replay.call`
      # @param right_result [Hash] `right`'s replay result, as returned by `Fuzzing::Replay.call`
      # @param left [Symbol] the adapter `left_result` was replayed against; becomes
      #   this entry's own key
      # @param right [Symbol] the adapter `right_result` was replayed against; becomes
      #   this entry's own key
      # @return [Array<Hash>] one `{field: "refusals", left => Object, right => Object}`
      #   entry if the two sides' normalized refusals differ; empty otherwise
      def diff_refusals(left_result, right_result, left, right)
        normalize = lambda do |refusals|
          refusals.map { |r| { "verb" => r[:verb].to_s, "kind" => r[:kind].to_s, "error" => r[:error] } }
        end
        l = normalize.call(left_result[:refusals])
        r = normalize.call(right_result[:refusals])
        return [] if l == r

        [{ field: "refusals", left => l, right => r }]
      end

      # Compares both sides' query answers.
      #
      # `Nondeterministic`'s `query_row` group dropped from every entry —
      # the same group `Differential.diff` drops, for the reason declared
      # there (already covered by `diff_instances` above).
      #
      # @param left_result [Hash] `left`'s replay result, as returned by `Fuzzing::Replay.call`
      # @param right_result [Hash] `right`'s replay result, as returned by `Fuzzing::Replay.call`
      # @param left [Symbol] the adapter `left_result` was replayed against; becomes
      #   this entry's own key
      # @param right [Symbol] the adapter `right_result` was replayed against; becomes
      #   this entry's own key
      # @return [Array<Hash>] one `{field: "queries", left => Object, right => Object}`
      #   entry if the two sides' stripped, JSON-shaped queries differ; empty otherwise
      def diff_queries(left_result, right_result, left, right)
        strip = ->(rows) { rows.map { |row| Nondeterministic.strip(row, :query_row) } }
        l = as_json(strip.call(left_result[:queries]))
        r = as_json(strip.call(right_result[:queries]))
        return [] if l == r

        [{ field: "queries", left => l, right => r }]
      end

      # Compares both sides' saga logs.
      #
      # @param left_result [Hash] `left`'s replay result, as returned by `Fuzzing::Replay.call`
      # @param right_result [Hash] `right`'s replay result, as returned by `Fuzzing::Replay.call`
      # @param left [Symbol] the adapter `left_result` was replayed against; becomes
      #   this entry's own key
      # @param right [Symbol] the adapter `right_result` was replayed against; becomes
      #   this entry's own key
      # @return [Array<Hash>] one `{field: "sagas", left => Object, right => Object}`
      #   entry if the two sides' JSON-shaped sagas differ; empty otherwise
      def diff_sagas(left_result, right_result, left, right)
        l = as_json(left_result[:sagas])
        r = as_json(right_result[:sagas])
        return [] if l == r

        [{ field: "sagas", left => l, right => r }]
      end

      # Compares both sides' reaction logs.
      #
      # @param left_result [Hash] `left`'s replay result, as returned by `Fuzzing::Replay.call`
      # @param right_result [Hash] `right`'s replay result, as returned by `Fuzzing::Replay.call`
      # @param left [Symbol] the adapter `left_result` was replayed against; becomes
      #   this entry's own key
      # @param right [Symbol] the adapter `right_result` was replayed against; becomes
      #   this entry's own key
      # @return [Array<Hash>] one `{field: "reactions", left => Object, right => Object}`
      #   entry if the two sides' JSON-shaped reactions differ; empty otherwise
      def diff_reactions(left_result, right_result, left, right)
        l = as_json(left_result[:reactions])
        r = as_json(right_result[:reactions])
        return [] if l == r

        [{ field: "reactions", left => l, right => r }]
      end
    end
  end
end
