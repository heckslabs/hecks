# frozen_string_literal: true

require_relative "../rules"

module Hecks
  module Adapters
    module PipelineBoard
      # Whether work is flowing, as the `Glance`'s `Flow` row: admission by the `Admission` rows,
      # the train by the `Train glance` rows, and what the fill would start next from its report.
      # The rows give the words; the reasons are what the owning aggregates and readers answered.
      module GlanceFlowing
        module_function

        # @param data [Hash] the board's sections as they were read, with the standing `load_guard`
        # @return [Hash] the `Flow` row
        def of(data)
          reasons = overload_reasons(data)
          { admission: Rules.verdict("Admission", { standing: standing(data, reasons) }), admission_why: reasons.join("; "),
            next_start: next_start(data[:fill]) }.merge(train(data[:train_prs]))
        end

        # @return [Array<String>] why admission is closed: each overload's reason, the load guard's
        def overload_reasons(data)
          overloads = data[:overloads].is_a?(Array) ? data[:overloads].map { |row| row[:reason] } : []
          guard = data[:load_guard]
          guard ? overloads + ["load #{guard[:load]} is above #{guard[:limit]}"] : overloads
        end

        # @return [Integer, nil] how many reasons stand; nil when neither was read
        def standing(data, reasons)
          reasons.size if data[:overloads].is_a?(Array) || data[:load_guard]
        end

        # @return [Array<Hash>] the `NextStart` rows the fill's report would start
        def next_start(fill)
          return [] unless fill.is_a?(Hash)

          Array(fill[:would_start]).map { |item| { slug: item[:slug].to_s, title: item[:title].to_s } }
        end

        # @return [Hash] `train_state` and `train_why` for the open train pull requests
        def train(pulls)
          return { train_state: Rules.verdict("Train glance", {}), train_why: "" } unless pulls.is_a?(Array)

          red = pulls.select { |pull| pull[:failed].to_i.positive? }
          { train_state: Rules.verdict("Train glance", measures(pulls, red)), train_why: named(red) }
        end

        def named(red) = red.map { |pull| "##{pull[:number]} red" }.join(", ")

        # @return [Hash] how many train pull requests are open, red and pending
        def measures(pulls, red)
          { open: pulls.size, red: red.size, pending: pulls.count { |pull| pull[:pending].to_i.positive? } }
        end
      end
    end
  end
end
