# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    # The world's rule for a started run whose session `claude` cannot be asked about: it is gone
    # when it started longer ago than the declared minutes and shows no process, no commit origin
    # lacks and no changed file within them.
    #
    # The facts are {RunActivity}'s; the minutes are the Tickets world's `run_gone_after` line.
    class RunGone
      # @param activity [RunActivity] reads the process table and the run's directory
      # @param minutes [#call] answers the minutes a run may show nothing before it is gone
      # @param now [#call] answers the time
      # @param stopped [#call, nil] answers the minutes a `stopped` session may stand over a run
      #   (the run's own minutes when none given)
      def initialize(activity, minutes:, now: -> { Time.now.utc }, stopped: nil)
        @activity = activity
        @minutes = minutes
        @stopped = stopped || minutes
        @now = now
      end

      # @param held [Hash] the `AgentRun` record: `session`, `repo` and `started_at`, plain values
      # @return [String, nil] why the run is gone, nil when it shows life or is too young to say
      def reason(held) = quiet_reason(held, @minutes.call)

      # @param held [Hash] the `AgentRun` record, as for {#reason}
      # @return [String, nil] why a run whose session `claude` lists `stopped` is gone, nil when it
      #   shows life or the session has not stood stopped over it for the declared minutes
      def stopped_reason(held)
        minutes = @stopped.call
        why = quiet_reason(held, minutes)
        "session stopped, and #{why}" if why
      end

      private

      def quiet_reason(held, minutes)
        limit = minutes * 60
        return unless age_of(held[:started_at]) > limit
        return if @activity.process?(held[:session], held[:repo])

        last = @activity.last_at(held[:repo])
        "no process, new commit or changed file for #{minutes} minutes" unless last && @now.call - last <= limit
      end

      def age_of(started)
        @now.call - Time.parse(started.to_s)
      rescue ArgumentError
        0
      end
    end
  end
end
