# frozen_string_literal: true

require "hecks/vocabulary"

module Hecks
  module Tools
    module Lanes
      # The `Lane` rows of the Vocabulary bluebook, checked against what the projection can express.
      module Rows
        # Empty, or a whole number (hours, or days).
        WHOLE_HOURS = /\A\d*\z/

        module_function

        # @return [Array<Hash{String => String}>] the `Lane` rows
        # @raise [SystemExit] when a row names a pusher or a lane the projection cannot express
        def all
          rows = Hecks::Vocabulary.rows("Lane")
          names = rows.map { |lane| lane["name"] }
          rows.each do |lane|
            problem = problem_with(lane, names)
            abort "lanes: #{problem}" if problem
          end
        end

        # @param lane [Hash{String => String}] a `Lane` row
        # @param names [Array<String>] every lane's name
        # @return [String, nil] what the projection cannot express about the row, or nil
        def problem_with(lane, names)
          name = lane["name"]
          return "#{name} has pushers #{lane["pushers"].inspect}" unless Lanes::PUSHERS.include?(lane["pushers"])
          return "#{name} has guarded #{lane["guarded"].inspect}" unless %w[yes no].include?(lane["guarded"])
          return "#{name} has alert_after #{lane["alert_after"].inspect}, not whole hours" unless hours?(lane)

          follows_problem(lane, names) || soak_problem(lane)
        end

        # @return [String, nil] what is wrong with the lane's soak settings, or nil
        def soak_problem(lane)
          bad = %w[soak_days major_soak_days].find { |key| !lane[key].to_s.match?(WHOLE_HOURS) }
          "#{lane["name"]} has #{bad} #{lane[bad].inspect}, not whole days" if bad
        end

        # @return [Boolean] whether `alert_after` is empty (never late) or whole hours
        def hours?(lane) = lane["alert_after"].to_s.match?(WHOLE_HOURS)

        def follows_problem(lane, names)
          follows = lane["follows"].to_s
          "#{lane["name"]} follows #{follows.inspect}, which is not a Lane row" unless follows.empty? || names.include?(follows)
        end
      end
    end
  end
end
