# frozen_string_literal: true

require "time"
require "hecks/hecks/adapters/console_capture"

module Hecks
  module Adapters
    class Standup
      # What a standup covers, as the bluebook's `StandupWindow` row states it: the hours back
      # from now when the caller names no time, and how many planned work items are listed.
      class Window
        # @param aggregate [Object, nil] the Work aggregate, whose `StandupWindow` row is read
        # @param now [Integer] the time the standup is read at, in epoch seconds
        def initialize(aggregate, now)
          @aggregate = aggregate
          @now = now
        end

        # @param text [String, nil] an ISO 8601 time the caller named
        # @return [Integer] that time, or the row's hours before now, in epoch seconds
        # @raise [ConsoleCapture::Failure] when the text is not an ISO 8601 time
        def since(text)
          return @now - (row[:hours].to_i * 3600) if text.to_s.empty?

          Time.iso8601(text.to_s).to_i
        rescue ArgumentError
          raise ConsoleCapture::Failure, "since is not an ISO 8601 time: #{text}"
        end

        # @return [Integer] how many planned work items a standup lists
        def upcoming = row[:upcoming].to_i

        private

        def row
          declared = @aggregate&.value_objects&.find { |object| object.hecks_name == "StandupWindow" }
          Array(declared&.members).first.to_h.transform_keys(&:to_sym)
        end
      end
    end
  end
end
