# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      module DailyHealth
        # The day's findings as the tile says them: each check that found something with its
        # count, and no key. The keys stay in the report's `line`, which the tile carries as
        # `full` for the person who opens it.
        module Summary
          module_function

          # @param checks [Array<Hash>] the `HealthCheck` rows
          # @param report [Hash] from {DailyHealth.build}
          # @return [String] the counts, or that nothing was found
          def of(checks, report)
            said = checks.filter_map { |row| counted(row, report[row[:kind].to_sym]) }
            unread = report[:unreadable]
            said << "#{unread.size} boardings with an unreadable commit" if unread.is_a?(Array) && unread.any?
            said.empty? ? "nothing found today" : said.join(", ")
          end

          def counted(row, found)
            return "#{row[:says]} unknown" unless found.is_a?(Array)

            "#{found.size} #{row[:says]}" if found.any?
          end
        end
      end
    end
  end
end
