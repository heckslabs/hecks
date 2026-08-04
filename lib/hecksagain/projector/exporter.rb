require "json"

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

      # Translation IR, always as an array. `values:` tables serialize as
      # `[key, value]` pairs, never an object, because JSON object keys are
      # always strings and a convert's keys are typed.
      def translations(registry)
        registry.translations.map { |translation| translation_hash(translation) }
      end

      def translation_hash(translation)
        {
          domain: translation.domain,
          from: translation.from,
          to: translation.to,
          retired: translation.retired,
          aggregates: translation.aggregates.map { |aggregate| translation_aggregate(aggregate) }
        }
      end

      def translations_json(registry)
        JSON.pretty_generate(translations(registry))
      end

      def translation_aggregate(aggregate)
        {
          name: aggregate.name,
          was: aggregate.was,
          renames: aggregate.renames.transform_keys(&:to_s).transform_values(&:to_s),
          moves: aggregate.moves.map { |move| { from: move.from, to: move.to } },
          converts: aggregate.converts.map do |convert|
            { from: convert.from, to: convert.to, values: convert.values.map { |key, value| [key, value] } }
          end,
          drops: aggregate.drops.map(&:to_s),
          retypes: aggregate.retypes.map { |retype| { from: retype.from, to: retype.to } },
          computes: aggregate.computes.map { |compute| { from: compute.from, to: compute.to, sql: compute.sql } }
        }
      end
    end
  end
end
