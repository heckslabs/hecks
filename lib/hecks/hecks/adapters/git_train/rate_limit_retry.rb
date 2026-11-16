# frozen_string_literal: true

module Hecks
  module Adapters
    class GitTrain
      # Runs a `gh` call again while GitHub answers that its rate limit is spent, a bounded number of
      # times with a growing wait, and answers the last `[ok, output]` whatever it was. It judges
      # nothing: the caller reads the answer, and `limited?` says whether a refusal was this one.
      class RateLimitRetry
        # What `gh` prints when the hourly budget, or a burst allowance, is gone.
        LIMITS = ["API rate limit", "secondary rate limit", "rate limit exceeded"].freeze

        # How many times a call runs before its last answer stands.
        ATTEMPTS = 4

        # Seconds before the first retry; each later one waits twice as long.
        FIRST_WAIT = 20

        # @param output [String, nil] what a failed `gh` call printed
        # @return [Boolean] whether it was refused for the rate limit
        def self.limited?(output) = LIMITS.any? { |limit| output.to_s.downcase.include?(limit.downcase) }

        # @param runner [#call] takes `(argv, chdir:)` and answers `[ok, output]`
        # @param pause [#call, nil] takes the seconds to wait; a spec replaces it
        # @param attempts [Integer] how many times a call runs at most
        def initialize(runner, pause: nil, attempts: ATTEMPTS)
          @runner = runner
          @pause = pause || ->(seconds) { sleep(seconds) }
          @attempts = attempts
        end

        # @param argv [Array<String>] the command
        # @param chdir [String] where it runs
        # @return [Array(Boolean, String)] the last answer: the first success, or the final refusal
        def call(argv, chdir:)
          answer = @runner.call(argv, chdir: chdir)
          (1...@attempts).each do |tried|
            break if answer.first || !self.class.limited?(answer.last)

            @pause.call(FIRST_WAIT * (2**(tried - 1)))
            answer = @runner.call(argv, chdir: chdir)
          end
          answer
        end
      end
    end
  end
end
