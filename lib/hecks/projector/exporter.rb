require "json"
require_relative "../runtime/era_check"
require_relative "../translation/rule_compiler"

module Hecks
  module Projector
    module Exporter
      module_function

      def call(registry)
        registry.bluebooks.transform_values(&:to_h)
      end

      def json(registry)
        JSON.pretty_generate(call(registry))
      end

      # A BINDING fact, deliberately NOT folded into `call`/`bluebook.to_h`
      # above — the canonical IR is runtime-independent by design (ADR
      # 0001: it describes what a bluebook DECLARES, never which adapter
      # a deployment happens to bind it to), and "is this aggregate bound
      # to a lineage-capable adapter" is exactly the kind of fact that
      # answer can change per-deployment without the bluebook's own shape
      # changing at all. Consumers that need it (bin/project_rust's own
      # `ir.json` sidecar, rust/host's runtime era-aware seed overlay —
      # dispatch.rs) merge this in as a SEPARATE top-level key, the same
      # way `translations` already sits beside `call`'s output rather than
      # inside it.
      #
      # Reuses `Runtime::EraCheck`'s own capability predicates rather than
      # re-deriving them — the boot-time gate and this export must never
      # answer differently for the same aggregate.
      def lineage(registry, domain_name)
        bluebook = registry.bluebooks.fetch(domain_name)
        capable = bluebook.aggregates.select do |aggregate|
          adapter_name = Runtime::EraCheck.adapter_for(registry, domain_name, aggregate)
          Runtime::EraCheck.lineage_capable?(registry, adapter_name)
        end

        { capable_aggregates: capable.map { |aggregate| { name: aggregate.name, storage_name: aggregate.storage_name } } }
      end

      # Translation IR, always as an array, WITH each aggregate's
      # precompiled SQL attached (`compiled_translation_aggregate`) —
      # this is the export a consumer embeds (`ir.json`'s `translations`
      # key), never the bare digest-relevant shape `edge_digest` hashes
      # (see that method's own header for why the two must stay
      # separate). `values:` tables serialize as `[key, value]` pairs,
      # never an object, because JSON object keys are always strings and
      # a convert's keys are typed.
      def translations(registry)
        registry.translations.map { |translation| compiled_translation_hash(translation) }
      end

      def compiled_translation_hash(translation)
        {
          domain:     translation.domain,
          from:       translation.from,
          to:         translation.to,
          retired:    translation.retired,
          aggregates: translation.aggregates.map { |aggregate| compiled_translation_aggregate(aggregate) }
        }
      end

      def translations_json(registry)
        JSON.pretty_generate(translations(registry))
      end

      # THE DIGEST-RELEVANT SHAPE — `ApprovalDigest.edge_digest` hashes
      # EXACTLY this, and only this, for exactly the reason `compiled_
      # translation_aggregate` below must never be used for that
      # purpose: a digest bound to the COMPILED SQL, not just the
      # DECLARED rules, would invalidate an existing human approval the
      # moment `Translation::RuleCompiler`'s own output format changed
      # for any reason — a compiler refactor, a cosmetic SQL-formatting
      # change — even when the declared rules an approver actually
      # reviewed never changed at all. The approval binds to WHAT WAS
      # DECLARED, not to what a particular compiler build happened to
      # emit from it.
      def translation_hash(translation)
        {
          domain:     translation.domain,
          from:       translation.from,
          to:         translation.to,
          retired:    translation.retired,
          aggregates: translation.aggregates.map { |aggregate| translation_aggregate(aggregate) }
        }
      end

      def translation_aggregate(aggregate)
        {
          name:      aggregate.name,
          was:       aggregate.was,
          renames:   aggregate.renames.transform_keys(&:to_s).transform_values(&:to_s),
          moves:     aggregate.moves.map { |move| { from: move.from, to: move.to } },
          converts:  aggregate.converts.map do |convert|
            { from: convert.from, to: convert.to, values: convert.values.map { |key, value| [key, value] } }
          end,
          drops:     aggregate.drops.map(&:to_s),
          retypes:   aggregate.retypes.map { |retype| { from: retype.from, to: retype.to } },
          computes:  aggregate.computes.map { |compute| { from: compute.from, to: compute.to, sql: compute.sql } },
          # PREVIOUSLY MISSING — found live while planning Rust-side mint
          # support. An edge carrying only a rekey (no compute) had its
          # approval bind to nothing rekey-specific at all: any two
          # rekey edges with otherwise-identical renames/moves/converts/
          # drops/retypes/computes produced the SAME digest regardless
          # of what their `rekey sql:` actually said, and a rekey's own
          # SQL could change without invalidating an existing approval.
          # Same bug shape for `backfills` (present, just never
          # exported). Fixing this CHANGES every existing rekey/
          # backfill edge's digest — any approval already recorded for
          # one is invalidated by this fix and must be re-reviewed.
          rekeys:    aggregate.rekeys.map { |rekey| { sql: rekey.sql } },
          backfills: aggregate.backfills.map { |backfill| { name: backfill.name.to_s, default: backfill.default } }
        }
      end

      # THE EXPORT SHAPE — `translation_aggregate`'s own digest-relevant
      # fields, plus the precompiled SQL (`compiled_state_expression`/
      # `compiled_id_expression`) a consumer embedding this JSON
      # (rust/host's own boot-time mint) needs to execute the edge
      # without compiling SQL itself. The SAME call head_compiler.rb's
      # own `compile_rules(declared)`/`id_case(guard, declared)` make at
      # mint time, run here once at build/export time instead —
      # `Translation::RuleCompiler` is the ONE place this expression is
      # built, called from both here and from head_compiler.rb's real
      # per-mint assembly, so a consumer gets Ruby's own compiler's
      # output verbatim, never a second, independently-authored SQL
      # compiler that could drift from this one. `compiled_id_
      # expression` is nil unless this edge rekeys — the bare
      # `aggregate_id` passthrough head_compiler.rb itself falls back to
      # for the overwhelming common case.
      def compiled_translation_aggregate(aggregate)
        translation_aggregate(aggregate).merge(
          compiled_state_expression: Translation::RuleCompiler.compile_rules(aggregate),
          compiled_id_expression:    Translation::RuleCompiler.rekeyed?(aggregate) ? Translation::RuleCompiler.compile_id_expression(aggregate) : nil
        )
      end
    end
  end
end
