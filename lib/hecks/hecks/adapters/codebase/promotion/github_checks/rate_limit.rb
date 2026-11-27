# frozen_string_literal: true

module Hecks
  module Adapters
    class GithubChecks
      # How long a run waits out GitHub's rate limit, and what it says while it does.
      #
      # A primary limit names its reset time, which is waited for when it falls within the budget. A
      # secondary limit names none, so it is waited out in short fixed steps. The budget is the
      # total a run may spend waiting; when the wait would pass it the run is told, by name, that it
      # is rate limited, and the budget is made whole for the next run.
      class RateLimit
        # What GitHub's answer says when it is refusing for a rate limit.
        PATTERN = /rate limit|abuse/i

        # Seconds a run may spend waiting in all.
        BUDGET = 300

        # Seconds waited when no reset time is known (a secondary limit).
        BACKOFF = 30

        # @param text [String] what `gh` said when it failed
        # @return [Boolean] whether GitHub is refusing for a rate limit
        def self.hit?(text) = text.to_s.match?(PATTERN)

        # @param sleeper [#call] waits the seconds it is given
        # @param now [#call] answers the time now
        # @param out [#puts] where the wait is announced
        def initialize(sleeper: ->(seconds) { sleep(seconds) }, now: -> { Time.now }, out: $stderr)
          @sleeper = sleeper
          @now = now
          @out = out
          @spent = 0
        end

        # Waits for GitHub to answer again.
        #
        # @param reset [Time, nil] when the limit lifts, nil when GitHub did not say
        # @return [void]
        # @raise [GithubChecks::RateLimited] when the wait would pass the budget
        def wait!(reset)
          seconds = reset ? [(reset - @now.call).ceil + 1, 1].max : BACKOFF
          give_up!(reset) if @spent + seconds > BUDGET
          @out.puts("waiting for rate limit: #{reset ? "until #{reset.utc.strftime("%H:%M:%SZ")}" : "#{seconds}s"}")
          @spent += seconds
          @sleeper.call(seconds)
        end

        private

        def give_up!(reset)
          @spent = 0
          raise RateLimited, reset ? "rate limited until #{reset.utc.strftime("%H:%M:%SZ")}" : "rate limited"
        end
      end
    end
  end
end
