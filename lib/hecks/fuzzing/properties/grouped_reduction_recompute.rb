require_relative "../../vocabulary"

module Hecks
  module Fuzzing
    module Properties
      # Independent checks of a read model that groups and reduces (ADR 0121), for
      # `InvariantsAndAggregation`: each leaf against the reduction recomputed over its own rows,
      # and the leaves folded by the reducer's declared `combine` against the ungrouped whole.
      module GroupedReductionRecompute
        # Each reducer's declared row of the Vocabulary's `Reducer` table, by name.
        REDUCERS = Hecks::Vocabulary.rows("Reducer").to_h { |row| [row["name"], row] }.freeze

        # How two partial answers fold, for each `combine` that is not `collect`. `nil` is a
        # group with no value, which every fold passes over, as the ungrouped reduction does.
        COMBINES = {
          "add" => ->(a, b) { a + b },
          "min" => ->(a, b) { [a, b].min },
          "max" => ->(a, b) { [a, b].max },
          "or"  => ->(a, b) { a || b },
          "and" => ->(a, b) { a && b }
        }.freeze

        # Judges a grouped reduction's answer: every leaf must equal the reduction recomputed
        # over that leaf's rows.
        #
        # @return [String, nil] the offense, or nil when the answer agrees
        def grouped_reduction_offense(asked, model, grouped_head, materialized)
          return nil if asked[:error]

          expected = nest_reduced_rows(model, materialized, model.group_by_fields)
          actual = answered(asked, grouped_head)
          return nil if actual == expected

          "#{asked[:query]} #{asked[:args].inspect} answered #{actual.inspect} for #{grouped_head[:as]}, but " \
            "reducing each group of #{materialized.length} eligible row(s) independently gives #{expected.inspect}"
        end

        # Judges whether a grouped answer's leaves, folded by the reducer's `combine`, add up to
        # the ungrouped reduction of the same rows; reducers that `collect` do not fold.
        #
        # @return [String, nil] the offense, or nil when they agree or the reducer does not fold
        def grouped_fold_offense(asked, model, reduced_head, rows)
          reducer = REDUCERS.fetch(reducer_name(model))
          return nil unless COMBINES.key?(reducer["combine"])

          folded = fold_leaves(answered(asked, reduced_head), reducer)
          whole = recompute_reduction(model, rows)
          return nil if folded == whole

          "#{asked[:query]} #{asked[:args].inspect}'s groups fold by #{reducer["combine"]} to #{folded.inspect}, " \
            "but reducing all #{rows.length} eligible row(s) at once gives #{whole.inspect}"
        end

        private

        def answered(asked, head) = asked[:rows]&.first&.dig(head[:as])

        # One level of nesting per field, each leaf the reduction of that leaf's rows.
        def nest_reduced_rows(model, rows, fields)
          field, *rest = fields
          rows.group_by { |row| row[field] }.transform_values do |group|
            stripped = group.map { |row| row.reject { |key, _| key == field } }
            rest.empty? ? recompute_reduction(model, stripped) : nest_reduced_rows(model, stripped, rest)
          end
        end

        # Every leaf of a nested answer, folded by the reducer's `combine`; no leaves answer
        # the reducer's identity.
        def fold_leaves(answer, reducer)
          leaves = leaf_values(answer).compact
          return JSON.parse(reducer["identity"]) if leaves.empty?

          leaves.reduce(&COMBINES.fetch(reducer["combine"]))
        end

        def leaf_values(answer)
          answer.is_a?(Hash) ? answer.values.flat_map { |value| leaf_values(value) } : [answer]
        end

        # The `Reducer` row name of the one reduction `model` declares.
        def reducer_name(model)
          ivar = Bluebook::Behaviour::ReadModel::REDUCTION_FIELDS.each_key.find { |name| model.public_send(name) }
          Bluebook::Behaviour::ReadModel::REDUCTION_FIELDS.fetch(ivar)
        end
      end
    end
  end
end
