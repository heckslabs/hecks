# frozen_string_literal: true

require "open3"
require "json"
require "date"

module Hecks
  module Adapters
    # The `CostExplorer` port's adapter: reads what an AWS account has billed, with the `aws`
    # command, and compares the monthly rate to a budget.
    #
    # It reads the daily unblended cost from the check's `since` day up to yesterday. Today is left
    # out because its bill is still partial, and a day is counted whatever Cost Explorer marks it
    # (a day stays "estimated" for a while after it ends). The rate is the mean daily cost scaled
    # to an average month. A rate within the budget is answered with a one-line report; a rate over
    # it, a span with no complete day, or a failed `aws` call is refused with a reason, which the
    # runtime records on the check.
    class CostExplorer
      # Days in an average month, for scaling a daily mean to a monthly rate.
      DAYS_IN_MONTH = 30.4375

      # How many of the biggest services the report names.
      TOP_SERVICES = 3

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `today:` pins the day the span ends before, for tests
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @today = settings[:today]
      end

      # Reads the billed cost since a day and compares its monthly rate to the budget.
      #
      # @param held [Hash] the check's fields: `budget:` whole dollars a month and `since:` the
      #   first day to count (`YYYY-MM-DD`), each a value object or a plain value
      # @return [Hash{Symbol => Hash}] `report:` the rate against the budget, the shape
      #   `CostCheck.Pass` takes
      # @raise [RuntimeError] when no complete day has passed since `since`, `aws` fails, or the
      #   rate is over the budget
      def measure(**held)
        budget = Integer(plain(held[:budget]))
        first = Date.iso8601(plain(held[:since]).to_s)
        last = today
        raise "no complete day since #{first}; today (#{last}) is still being billed" if first >= last

        days = daily_costs(first, last)
        line = report_line(first, last, days, budget)
        raise "over budget: #{line}" if monthly_rate(days) > budget

        { report: { value: line } }
      end

      private

      # @return [Date] the day the span ends before: today, in UTC
      def today = @today ? Date.iso8601(@today.to_s) : Time.now.utc.to_date

      # @return [Hash{String => Hash{String => Float}}] day => service => dollars
      def daily_costs(first, last)
        out, err, status = Open3.capture3(
          "aws", "ce", "get-cost-and-usage", "--time-period", "Start=#{first},End=#{last}",
          "--granularity", "DAILY", "--metrics", "UnblendedCost",
          "--group-by", "Type=DIMENSION,Key=SERVICE", "--output", "json"
        )
        raise "aws ce get-cost-and-usage failed: #{err.strip.empty? ? out.strip : err.strip}" unless status.success?

        rows = JSON.parse(out).fetch("ResultsByTime")
        raise "Cost Explorer returned no days for #{first}..#{last}" if rows.empty?

        rows.to_h { |row| [row.dig("TimePeriod", "Start"), by_service(row)] }
      end

      def by_service(row)
        row.fetch("Groups").to_h do |group|
          [group.fetch("Keys").first, group.dig("Metrics", "UnblendedCost", "Amount").to_f]
        end
      end

      # @return [Float] the mean daily total, scaled to an average month
      def monthly_rate(days)
        mean = days.values.sum { |services| services.values.sum } / days.size
        mean * DAYS_IN_MONTH
      end

      def report_line(first, last, days, budget)
        mean = days.values.sum { |services| services.values.sum } / days.size
        biggest = totals_by_service(days).max_by(TOP_SERVICES) { |_name, dollars| dollars }
        named = biggest.map { |name, dollars| "#{name} $#{format("%.2f", dollars / days.size)}/day" }.join(", ")
        "#{first}..#{last - 1} (#{days.size} days): $#{format("%.2f", mean)}/day, " \
          "$#{format("%.2f", monthly_rate(days))}/month against $#{budget}; biggest: #{named}"
      end

      def totals_by_service(days)
        days.values.each_with_object(Hash.new(0.0)) do |services, totals|
          services.each { |name, dollars| totals[name] += dollars }
        end
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
