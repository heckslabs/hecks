# frozen_string_literal: true

require "json"
require "time"

module Hecks
  module Adapters
    class LandingPaceReading
      # Pairs each landing with the moment its change was ready, as the `Pace` query defines it:
      # the first request to land it that names its branch or is the landing's own run, since
      # that branch last landed. A refused attempt between the two is part of the wait. A finish
      # names no branch, so one that was refused and asked again under a new run is counted from
      # the run that landed.
      class Pairing
        # The events that ask for a branch to land.
        REQUESTS = %w[LandingSubmitted FinishRequested LandingRequested CarryRequested TrainRequested].freeze

        # One landing: `wait` is the seconds from ready to landed, nil when no request was found.
        Landed = Struct.new(:branch, :at, :wait)

        # @return [Array<Landed>] the landings, oldest first
        attr_reader :landed

        # @return [Integer] how many requests were refused
        attr_reader :refused

        # @param events [Array<Hash>] `Landing` events, oldest first, as a trace reader answers them
        def initialize(events)
          @by_branch = {}
          @by_run = {}
          @landed = []
          @refused = 0
          events.each { |event| take(event) }
        end

        private

        def take(event)
          case event["name"]
          when "BranchLanded" then land(event)
          when "LandingRefused" then @refused += 1
          when *REQUESTS then ask(event)
          end
        end

        def ask(event)
          at = Time.iso8601(event["occurred_at"])
          @by_run[event["aggregate_id"]] ||= at
          branch = branch_of(event)
          @by_branch[branch] ||= at if branch
        end

        def land(event)
          at = Time.iso8601(event["occurred_at"])
          branch = branch_of(event)
          ready = [@by_branch.delete(branch), @by_run.delete(event["aggregate_id"])].compact.min
          @landed << Landed.new(branch, at, ready && (at - ready))
        end

        def branch_of(event) = JSON.parse(event["payload"] || "{}").dig("branch", "value")
      end
    end
  end
end
