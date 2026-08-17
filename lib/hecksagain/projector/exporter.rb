require "json"
require_relative "../runtime/era_check"

module Hecksagain
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

      # Translation IR, always as an array. `values:` tables serialize as
      # `[key, value]` pairs, never an object, because JSON object keys are
      # always strings and a convert's keys are typed.
      def translations(registry)
        registry.translations.map { |translation| translation_hash(translation) }
      end

      def translation_hash(translation)
        {
          domain:     translation.domain,
          from:       translation.from,
          to:         translation.to,
          retired:    translation.retired,
          aggregates: translation.aggregates.map { |aggregate| translation_aggregate(aggregate) }
        }
      end

      def translations_json(registry)
        JSON.pretty_generate(translations(registry))
      end

      def translation_aggregate(aggregate)
        {
          name:     aggregate.name,
          was:      aggregate.was,
          renames:  aggregate.renames.transform_keys(&:to_s).transform_values(&:to_s),
          moves:    aggregate.moves.map { |move| { from: move.from, to: move.to } },
          converts: aggregate.converts.map do |convert|
            { from: convert.from, to: convert.to, values: convert.values.map { |key, value| [key, value] } }
          end,
          drops:    aggregate.drops.map(&:to_s),
          retypes:  aggregate.retypes.map { |retype| { from: retype.from, to: retype.to } },
          computes: aggregate.computes.map { |compute| { from: compute.from, to: compute.to, sql: compute.sql } }
        }
      end
    end
  end
end
