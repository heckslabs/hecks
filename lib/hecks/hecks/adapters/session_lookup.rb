# frozen_string_literal: true

require "time"
require_relative "console_capture"
require_relative "claude_session_listing"

module Hecks
  module Adapters
    # Says whether `claude agents` still lists a run's session, for the policies that retire a run
    # whose session is gone.
    #
    # A session that was only just started is not yet in the listing and has not yet written its
    # job state, so for the first seconds "not listed" does not mean gone: a run younger than the
    # grace the Tickets world declares is answered as still there, and retired only if it is still
    # missing after that. A session the listing does show is not looked up again for five
    # minutes, because a session that stays listed with no state file would otherwise cost a
    # listing and a refusal on every beat. When the sessions cannot be listed at all (`claude` is
    # missing or fails), a run is gone only by the world's rule ({RunGone}); else the
    # refusal stands.
    class SessionLookup
      # Seconds a "still listed" answer is kept for a run.
      THROTTLE = 300

      # @param listing [#find] looks a session up in the `claude agents` listing
      # @param grace [#call] answers the seconds a started session is given to appear
      # @param now [#call] answers the time
      # @param gone [#reason, nil] says why a run is gone when the sessions cannot be listed
      def initialize(listing, grace:, now: -> { Time.now.utc }, gone: nil)
        @listing = listing
        @gone = gone
        @grace = grace
        @now = now
        @seen = {}
      end

      # @param held [Hash] the `AgentRun` record: `run`, `session` and `started_at`
      # @return [Hash{Symbol => Object}] `listed:` whether the session is listed (true as well while
      #   it is within its grace), `state:` its state there, and `note:` that in words
      # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
      def call(held)
        id = plain(held[:session]).to_s
        return missing(id) if id.empty?

        kept(plain(held[:run]).to_s) || found(held, id) || young(held, id) || missing(id)
      rescue ConsoleCapture::Failure => e
        abandoned(held, id, e)
      end

      private

      # The refusal stands unless the world's rule says the run is gone without the listing.
      def abandoned(held, id, refusal)
        why = @gone&.reason(held.transform_values { |value| plain(value) })
        raise refusal unless why

        { listed: false, state: "", note: "session #{id} cannot be listed (#{refusal.message}); #{why}" }
      end

      def kept(run)
        seen = @seen[run]
        seen[:answer] if seen && @now.call - seen[:at] < THROTTLE
      end

      def found(held, id)
        entry = @listing.find(id)
        return unless entry

        stopped_gone(held, id, entry) || keep(held, id, entry)
      end

      # A session listed as ended (stopped, done or failed) over a run that shows nothing for the
      # declared minutes is gone; one that works, is blocked or has life around it is not.
      def stopped_gone(held, id, entry)
        state = entry["state"].to_s
        return unless ClaudeSessionListing::ENDED.include?(state) && @gone.respond_to?(:stopped_reason)

        why = @gone.stopped_reason(held.transform_values { |value| plain(value) })
        { listed: false, state: state, note: "session #{id} is listed #{state}; #{why}" } if why
      end

      def keep(held, id, entry)
        answer = { listed: true, state: entry["state"].to_s, note: "session #{id} is still listed, #{entry["state"]}" }
        @seen[plain(held[:run]).to_s] = { at: @now.call, answer: answer }
        answer
      end

      def young(held, id)
        age = age_of(held)
        return unless age && age < @grace.call

        { listed: true, state: "", note: "session #{id} is not listed yet; it started #{age.to_i}s ago" }
      end

      def age_of(held)
        began = Time.parse(plain(held[:started_at]).to_s)
        @now.call - began
      rescue ArgumentError
        nil
      end

      def missing(id) = { listed: false, state: "", note: "session #{id} is not listed" }

      def plain(value) = value.is_a?(Hash) ? value[:value] : value
    end
  end
end
