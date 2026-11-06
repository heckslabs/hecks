# frozen_string_literal: true

module Hecks
  module Adapters
    class IterationWatch
      # The over-budget rule: the time since the claim passed `over_budget` times the row's budget.
      # A row with no budget uses `default_budget_minutes`; a row with no claim time is not timed.
      class Budget
        # @param limits [Setting::Limits]
        def initialize(limits)
          @limits = limits
        end

        # @param row [Hash] `claimed_at:` (Time or nil) and `budget_minutes:` (0 when none)
        # @param now [Integer, Float] the time now, in epoch seconds
        # @return [String, nil] the line that says the rule tripped, nil when it did not
        def call(row, now)
          return unless row[:claimed_at]

          budget = row[:budget_minutes].to_i.positive? ? row[:budget_minutes] : @limits.default_budget_minutes
          elapsed = (now - row[:claimed_at].to_i) / 60
          "#{elapsed.round} of #{budget} min" if elapsed > budget * @limits.over_budget
        end
      end
    end
  end
end
