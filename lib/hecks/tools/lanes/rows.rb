# frozen_string_literal: true

require "hecks/vocabulary"

module Hecks
  module Tools
    module Lanes
      # The `Lane` rows of the Vocabulary bluebook, checked against what the projection can express.
      module Rows
        # Empty, or a trailer key of dash-joined words such as `Release-Approved-By`.
        TRAILER_KEY = /\A([A-Za-z][A-Za-z0-9]*(-[A-Za-z0-9]+)*)?\z/

        # Empty, or a whole number of hours.
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

          watch_problem(lane) || local_gate_problem(lane) || follows_problem(lane, names)
        end

        # @param lane [Hash{String => String}] a `Lane` row
        # @return [String, nil] what is wrong with the lane's alert threshold or release trailer, or nil
        def watch_problem(lane)
          name = lane["name"]
          return "#{name} has alert_after #{lane["alert_after"].inspect}, not whole hours" unless hours?(lane)

          "#{name} has release_trailer #{lane["release_trailer"].inspect}, not a trailer word" unless trailer?(lane)
        end

        # @param lane [Hash{String => String}] a `Lane` row
        # @return [String, nil] what is wrong with the lane's local gate columns, or nil
        def local_gate_problem(lane)
          gate_problem(lane) || (train_problem(lane) unless %w[yes no].include?(lane["train"].to_s))
        end

        def train_problem(lane) = "#{lane["name"]} has train #{lane["train"].inspect}, not yes or no"

        def gate_problem(lane)
          stages = Hecks::Vocabulary.rows("GateStage").map { |stage| stage["name"] }
          column = %w[push_gate full_gate].find { |key| !lane[key].to_s.empty? && !stages.include?(lane[key]) }
          "#{lane["name"]} has #{column} #{lane[column].inspect}, which is not a GateStage row" if column
        end

        # @return [Boolean] whether `release_trailer` is empty (nothing is released from the lane)
        #   or a git trailer key such as `Release-Approved-By`
        def trailer?(lane) = lane["release_trailer"].to_s.match?(TRAILER_KEY)

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
