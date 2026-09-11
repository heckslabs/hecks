require "json"
require_relative "replay"

module Hecks
  module Fuzzing
    # THE SECOND DIFFERENTIAL AXIS — bin/qa_sweep's own `diff_ruby_vs_rust`
    # compares two DIFFERENT ENGINES (the Ruby interpreter vs the compiled
    # Rust kernel) against the SAME persistence (Memory, always — see
    # `SequenceGenerator`'s own header: sequence GENERATION stays
    # Memory-only, and `IsolatedBoot`'s own header explains why every
    # existing fuzz/replay path structurally cannot reach a real Postgres-
    # bound domain's own SQL compilation). This module compares the
    # opposite pairing: the SAME ONE Ruby engine, against two DIFFERENT
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
    # NOT a replacement for `bin/qa_sweep`'s own Ruby-vs-Rust differential
    # mode — a genuinely separate axis, opt-in (`--persistence-parity`),
    # because this one pays for a real `PG.connect` and real SQL per
    # dispatch where Memory-vs-Rust pays for neither. See `bin/qa_sweep`'s
    # own `--persistence-parity` handling for the seed-count dial that
    # keeps that cost bounded.
    #
    # `database:`/`schema:` — REQUIRED, no default: the caller (today,
    # only `bin/qa_sweep`) owns the disposable database's whole lifecycle
    # (created before the sweep, dropped after — see that script's own
    # comment), exactly the discipline `spec/qa_sweep_all_spec.rb`'s own
    # header already established for the ledger's own disposable Postgres
    # database, and exactly the discipline `IsolatedBoot#rebind_to_
    # postgres_era!` refuses to let a caller skip.
    module PersistenceParity
      module_function

      # THE SAME SIX FIELDS `bin/qa_sweep`'s own `diff_ruby_vs_rust`
      # compares (its own comment: "instances, events, refusals, queries,
      # sagas, reactions") — deliberately the identical set, so a report
      # this mode produces reads exactly like the sibling mode's own,
      # differing only in which two things were compared, not in what
      # "found something" means.
      #
      # SIMPLER NORMALIZATION THAN `diff_ruby_vs_rust`, on purpose — that
      # method reduces Rust's OWN JSON-over-stdout output to "wire
      # precision" and filters known Ruby/Rust structural gaps, because
      # it is comparing two genuinely different engines that are allowed
      # to differ in already-catalogued, understood ways. Both sides here
      # are the SAME Ruby engine (`Replay.call`, called twice, adapter
      # only) — there is no second engine's own known-gap catalogue to
      # filter against, so any real difference IS the finding. Both
      # results still round-trip through `JSON.generate`/`JSON.parse`
      # before comparing, matching `diff_ruby_vs_rust`'s own discipline —
      # not because either side needs a wire-format reduction, but so
      # `Hash#==`/`Array#==` compares plain, JSON-shaped data on both
      # sides identically (a `Runtime::Value`, a `Symbol` key, a `Time`
      # nobody asked for — none of that survives an accidental leak into
      # this comparison unnoticed).
      def diff(domain_path, steps, database:, schema:)
        memory_result = Replay.call(domain_path, steps, adapter: :memory)
        postgres_result = Replay.call(domain_path, steps, adapter: :postgres_era, database: database, schema: schema)

        divergences = []
        divergences.concat(diff_instances(memory_result, postgres_result))
        divergences.concat(diff_events(memory_result, postgres_result))
        divergences.concat(diff_refusals(memory_result, postgres_result))
        divergences.concat(diff_queries(memory_result, postgres_result))
        divergences.concat(diff_sagas(memory_result, postgres_result))
        divergences.concat(diff_reactions(memory_result, postgres_result))
        divergences
      end

      def as_json(value) = JSON.parse(JSON.generate(value))

      def diff_instances(memory_result, postgres_result)
        memory   = as_json(memory_result[:instances])
        postgres = as_json(postgres_result[:instances])
        return [] if memory == postgres

        [{ field: "instances", memory: memory, postgres_era: postgres }]
      end

      def diff_events(memory_result, postgres_result)
        memory   = as_json(memory_result[:events])
        postgres = as_json(postgres_result[:events])
        return [] if memory == postgres

        [{ field: "events", memory: memory, postgres_era: postgres }]
      end

      # `verb:`/`kind:` normalized to plain strings the same way
      # `diff_ruby_vs_rust`'s own `ruby_refusals` mapping does — both
      # sides here already answer strings (`Replay#refusal_kind` always
      # returns one), so this is belt-and-suspenders consistency with the
      # sibling mode's own shape, not a real coercion.
      def diff_refusals(memory_result, postgres_result)
        normalize = lambda do |refusals|
          refusals.map { |r| { "verb" => r[:verb].to_s, "kind" => r[:kind].to_s, "error" => r[:error] } }
        end
        memory   = normalize.call(memory_result[:refusals])
        postgres = normalize.call(postgres_result[:refusals])
        return [] if memory == postgres

        [{ field: "refusals", memory: memory, postgres_era: postgres }]
      end

      # `instances_at:` dropped from every entry — the same reason
      # `diff_ruby_vs_rust` excludes it (`row.except(:instances_at)`):
      # it is a full state snapshot taken for the QUERY oracle's own use,
      # already covered by `diff_instances` above, and would make every
      # query-step entry re-litigate the SAME instances divergence a
      # second time under a different field name.
      def diff_queries(memory_result, postgres_result)
        strip = ->(rows) { rows.map { |row| row.except(:instances_at) } }
        memory   = as_json(strip.call(memory_result[:queries]))
        postgres = as_json(strip.call(postgres_result[:queries]))
        return [] if memory == postgres

        [{ field: "queries", memory: memory, postgres_era: postgres }]
      end

      def diff_sagas(memory_result, postgres_result)
        memory   = as_json(memory_result[:sagas])
        postgres = as_json(postgres_result[:sagas])
        return [] if memory == postgres

        [{ field: "sagas", memory: memory, postgres_era: postgres }]
      end

      def diff_reactions(memory_result, postgres_result)
        memory   = as_json(memory_result[:reactions])
        postgres = as_json(postgres_result[:reactions])
        return [] if memory == postgres

        [{ field: "reactions", memory: memory, postgres_era: postgres }]
      end
    end
  end
end
