require "json"
require_relative "replay"
require_relative "nondeterministic"

module Hecks
  module Fuzzing
    # Differential check of one Ruby engine against two persistences, `left:` and `right:`.
    # Defaults to Memory vs a disposable `PostgresEra` database, which needs `database:`/`schema:`.
    module PersistenceParity
      module_function

      # Replays `steps` on both adapters and lists where the results differ.
      #
      # Compares the same six fields as `hecks quality_control ask run`'s Ruby-vs-Rust mode. Both
      # results are JSON-round-tripped so plain data compares equal on both sides.
      #
      # @param left [Symbol] an `IsolatedBoot` adapter: `:memory`, `:sqlite`, `:postgres`,
      #   `:postgres_era`
      # @param right [Symbol] the second adapter, same set as `left`
      # @param database [String, nil] required when either side is `:postgres_era`
      # @param schema [String, nil] required when either side is `:postgres_era`
      # @return [Array<Hash>] entries `{field: String, left => Object, right => Object}`,
      #   keyed by the adapter symbols; empty if both sides agree
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

      # Round-trips `value` through JSON so both sides compare as plain data.
      def as_json(value) = JSON.parse(JSON.generate(value))

      # Compares both sides' stored instances.
      def diff_instances(left_result, right_result, left, right)
        l = as_json(left_result[:instances])
        r = as_json(right_result[:instances])
        return [] if l == r

        [{ field: "instances", left => l, right => r }]
      end

      # Compares both sides' emitted events.
      def diff_events(left_result, right_result, left, right)
        l = as_json(left_result[:events])
        r = as_json(right_result[:events])
        return [] if l == r

        [{ field: "events", left => l, right => r }]
      end

      # Compares both sides' refusals, with `verb`/`kind` as strings.
      def diff_refusals(left_result, right_result, left, right)
        normalize = lambda do |refusals|
          refusals.map { |r| { "verb" => r[:verb].to_s, "kind" => r[:kind].to_s, "error" => r[:error] } }
        end
        l = normalize.call(left_result[:refusals])
        r = normalize.call(right_result[:refusals])
        return [] if l == r

        [{ field: "refusals", left => l, right => r }]
      end

      # Compares both sides' query answers, minus the `query_row` fields.
      #
      # The `Nondeterministic` `query_row` group is dropped; instances are already compared.
      def diff_queries(left_result, right_result, left, right)
        strip = ->(rows) { rows.map { |row| Nondeterministic.strip(row, :query_row) } }
        l = as_json(strip.call(left_result[:queries]))
        r = as_json(strip.call(right_result[:queries]))
        return [] if l == r

        [{ field: "queries", left => l, right => r }]
      end

      # Compares both sides' saga logs.
      def diff_sagas(left_result, right_result, left, right)
        l = as_json(left_result[:sagas])
        r = as_json(right_result[:sagas])
        return [] if l == r

        [{ field: "sagas", left => l, right => r }]
      end

      # Compares both sides' reaction logs.
      def diff_reactions(left_result, right_result, left, right)
        l = as_json(left_result[:reactions])
        r = as_json(right_result[:reactions])
        return [] if l == r

        [{ field: "reactions", left => l, right => r }]
      end
    end
  end
end
