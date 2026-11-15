# frozen_string_literal: true

require "time"
require_relative "../probe"

module Hecks
  module Adapters
    module PipelineBoard
      # What GitHub's hourly budget allows the board to read. It measures from `gh api rate_limit`
      # (a read GitHub does not count) and refuses a read whose budget is nearly spent, so the
      # board says so on its cards instead of failing every one of them and spending what is left.
      #
      # The threshold is the share of the limit that must remain, `percent` here; it is a dial of
      # this reader, not a rule of the board's domain. The `gh` commands that run on GraphQL are
      # `pr`, `repo`, `release`, `issue` and `search`; every other read (`api`, `run`) is REST.
      class Budget
        # The share of a budget (percent) under which reads pause.
        PAUSE_PERCENT = 10

        # The `gh` commands whose reads spend the GraphQL budget.
        GRAPHQL = %w[pr repo release issue search project].freeze

        # @param stand [#call] answers `gh api rate_limit` parsed
        # @param percent [Numeric, nil] the share that must remain; {PAUSE_PERCENT} when nil
        def initialize(stand, percent: nil)
          @stand = stand
          @percent = percent || PAUSE_PERCENT
        end

        # @param args [Array<String>] the `gh` arguments about to be run
        # @return [void]
        # @raise [Unavailable] `GitHub reads paused until HH:MM` when the budget they spend is
        #   under the share that must remain
        def check!(args)
          return if args.first(2) == %w[api rate_limit]

          found = resource(GRAPHQL.include?(args.first) ? "graphql" : "core")
          raise Unavailable, "GitHub reads paused until #{Time.at(found["reset"].to_i).strftime("%H:%M")}" if low?(found)
        end

        private

        def low?(found) = found && found["remaining"].to_f * 100 < found["limit"].to_f * @percent

        # The budget's standing, nil when it cannot be read (reads are then not held back).
        def resource(name)
          standing = @stand.call
          standing.dig("resources", name) if standing.is_a?(Hash)
        rescue Unavailable
          nil
        end
      end
    end
  end
end
