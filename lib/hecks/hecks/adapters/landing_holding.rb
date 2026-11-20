# frozen_string_literal: true

require_relative "red_flag_guard"
require_relative "boarding_hold_marker"
require_relative "console_capture"
require "hecks/indifferent_key"

module Hecks
  module Adapters
    # The `Holds` port's adapter: what this repository's pipeline holds a landing onto main for.
    #
    # Delivery asks it and knows neither reason. A boarding hold on main refuses a landing before
    # it takes a place in the line, and a standing red flag refuses one just before it merges;
    # the fix of a red Work item passes both. A fix that lands records main's new commit on the
    # flag, so the push train may board it.
    class LandingHolding
      # @param registry [Runtime::Registry, nil] the booted registry, for the world's
      #   `boarding_hold` window
      def initialize(registry: nil)
        @registry = registry
      end

      # @param branch [String] the branch about to land
      # @param git_dir [String] the repository's common git directory
      # @return [Hash{Symbol => Hash}] `report:` saying nothing holds main
      # @raise [ConsoleCapture::Failure] when main is held for a boarding and the branch is not a
      #   red Work item's fix
      def hold(branch:, git_dir:, **)
        unless RedFlagGuard.fix?(branch)
          marker = BoardingHoldMarker.new(git_dir, minutes: hold_window)
          held = marker.active
          raise ConsoleCapture::Failure, marker.refusal(held) if held
        end
        { report: { value: "no boarding hold stops #{branch}" } }
      end

      # @param branch [String] the branch about to merge onto main
      # @param git_dir [String] the repository's common git directory
      # @return [Hash{Symbol => Hash}] `report:` saying no flag stops the branch
      # @raise [ConsoleCapture::Failure] when a flag stands and the branch is not a red Work item's
      #   fix
      def flag(branch:, git_dir:, **)
        RedFlagGuard.new(git_dir).landing!(branch)
        { report: { value: "no red flag stops #{branch}" } }
      end

      # @param branch [String] the branch that landed on main
      # @param tip [String] main's commit after the landing
      # @param git_dir [String] the repository's common git directory
      # @return [Hash{Symbol => Hash}] `report:` naming the landing recorded
      def record_landing(branch:, tip:, git_dir:, **)
        RedFlagGuard.new(git_dir).landed(branch, tip)
        { report: { value: "#{branch} landed as #{tip}" } }
      end

      private

      # The minutes a hold lasts: the world's `boarding_hold` setting, else the default.
      def hold_window
        setting = (@registry&.world("Hecks")&.settings || {})["boarding_hold"]
        (setting && IndifferentKey.read(setting, :max_minutes)) || BoardingHoldMarker::DEFAULT_MINUTES
      end
    end
  end
end
