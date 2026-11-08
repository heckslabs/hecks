# frozen_string_literal: true

module Hecks
  module Adapters
    class PriorityReport
      # The text of the report: a header of counts, then one line for each row that passes the
      # tier filter and the limit, each fitted to the width.
      class Lines
        # The tiers in the order the header lists them.
        TIERS = %w[red now next later none].freeze

        # @param rows [Array<Backlog::Row>] every open item, in dispatch order
        # @param started [Integer] how many work items are started
        # @param cap [Integer] the cap on started work items
        def initialize(rows, started:, cap:)
          @rows = rows
          @started = started
          @cap = cap
        end

        # @param tier [String, nil] keeps only the rows of this tier
        # @param limit [Integer, nil] keeps only this many rows
        # @param width [Integer, nil] cuts each line to this many columns
        # @return [String] the report, ending in a newline
        def text(tier: nil, limit: nil, width: nil)
          shown = @rows.select { |row| tier.to_s.empty? || row.tier == tier.to_s }
          shown = shown.first(limit.to_i) if limit
          "#{([header] + shown.map { |row| fit(line(row), width) }).join("\n")}\n"
        end

        private

        def header
          counts = TIERS.map { |tier| "#{tier} #{@rows.count { |row| row.tier == tier }}" }
          "#{counts.join(", ")}; started #{@started} of cap #{@cap}"
        end

        def line(row)
          [row.position.to_s.rjust(3), row.tier.ljust(5), "step #{row.step || "-"}".ljust(8), row.key, row.status,
           row.area.empty? ? "-" : row.area, row.note].join("  ")
        end

        def fit(text, width)
          width && text.length > width.to_i ? "#{text[0, width.to_i - 1]}…" : text
        end
      end
    end
  end
end
