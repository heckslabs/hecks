# frozen_string_literal: true

require_relative "git"
require_relative "console_capture"
require_relative "boarding_hold_marker"
require_relative "../../indifferent_key"

module Hecks
  module Adapters
    # What the `Holding` and `Releasing` adapters share: finding a repository's marker, with the
    # window the world's `boarding_hold` setting names, from any directory of the repository. The
    # including class answers `@git`, `@settings` and `@registry`.
    module BoardingHoldMarking
      private

      def marker_of(held)
        BoardingHoldMarker.new(read(held, "rev-parse", "--path-format=absolute", "--git-common-dir"),
                               minutes: @settings[:minutes] || window, clock: @settings[:clock] || -> { Time.now })
      end

      def window
        setting = (@registry&.world("Hecks")&.settings || {})["boarding_hold"]
        (setting && IndifferentKey.read(setting, :max_minutes)) || BoardingHoldMarker::DEFAULT_MINUTES
      end

      def read(held, *args)
        result = @git.capture(*args, chdir: plain(held[:checkout]) || Dir.pwd)
        raise ConsoleCapture::Failure, "git #{args.first(2).join(" ")}: #{result.out.strip}" unless result.ok?

        result.out.strip
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
