# frozen_string_literal: true

require "hecks/roundhouse/adapters/metering"
require "hecks/hecks/adapters/claude_session_listing"
require_relative "signalbox_door"

module Hecks
  module Adapters
    class Dispatching
      # Protection coordination for a fill (ADR 0222, phase 3, protection): Signalbox's breakers,
      # put to `Breaker.Trip` by dry run in the order its Order rows declare, so the smallest
      # breaker that can act acts first and the boot-hours machine fuse trips last. It only
      # assembles each breaker's load and rating; whether one trips, and whether a tripped one holds
      # new coders, is the bluebook's.
      #
      # Two breakers are read at a fill: the helper share (live helpers against the live coders
      # times the share, from Roundhouse's meter) and the machine fuse (the boots' share of the
      # CPU over the last minutes, read only while the load is over its high mark). The session
      # fuse is Roundhouse's, blown on its meter; shedding has Delegate's own `Shed`; the model
      # fuse is unrated until ADR 0220's bound is set.
      class Protecting
        # The helper share, in percent of the live coders, when the Signalbox world declares none.
        SHARE_PERCENT = 100
        # The units each breaker's amounts are said in.
        UNITS = { "helpers" => "helpers", "machine" => "percent of CPU in boots" }.freeze

        # @param share [#call] answers the machine fuse's `load:` and `rating:`, nil when the load
        #   is under its high mark
        # @param sessions [#call] the live sessions, each with its `role`; Roundhouse's meter's
        # @param door [SignalboxDoor] the handle on Signalbox
        def initialize(share:, sessions:, door: SignalboxDoor.shared)
          @share = share
          @sessions = sessions
          @door = door
        end

        # @return [Hash, nil] the breaker that acts first, its Order row with `load:` and `rating:`;
        #   nil when none trips
        def acting
          return @acting if defined?(@acting)

          @acting = tripped.first
        end

        # @return [String, nil] why no coder starts: the acting breaker holds new starts; nil
        #   otherwise
        def stop
          acting && acting[:holds] == "yes" ? "skipped: breaker #{acting[:level]} tripped: #{amounts(acting)}" : nil
        end

        # @return [String] the clause a fill's header says of protection
        def clause
          return "protection: no breaker trips (#{readings_line})" unless acting

          "protection: #{acting[:level]} acts first (#{amounts(acting)}); the larger breakers wait"
        end

        private

        # Each breaker with a reading, smallest first, that trips while the ones before it that
        # tripped are counted as able to act.
        def tripped
          @door.order.each_with_object([]) do |row, found|
            reading = readings[row[:level]]
            next unless reading

            refused = @door.trip_refusal(row[:level], **reading, smaller_ready: found.size)
            found << row.merge(reading) unless refused
          end
        end

        def readings
          @readings ||= { "helpers" => helper_reading, "machine" => machine_reading }.compact
        end

        # Coders and helpers alike are counted only while their session has not ended: a session
        # listed stopped, done or failed whose process lingers neither loads nor rates the share.
        def helper_reading
          roles = @sessions.call.reject { |session| ended?(session) }.map { |session| session[:role].to_s }
          share = (@door.setting("breakers")[:helpers_percent] || SHARE_PERCENT).to_i
          { load: roles.count("helper"), rating: roles.count("coder") * share / 100 }
        end

        def ended?(session) = ClaudeSessionListing::ENDED.include?(session[:state].to_s)

        def machine_reading = @share.call

        def amounts(reading) = "#{reading[:load]} of #{reading[:rating]} #{UNITS[reading[:level]]}".strip

        def readings_line
          readings.map { |level, reading| "#{level} #{amounts(reading.merge(level: level))}" }.join(", ")
        end
      end
    end
  end
end
