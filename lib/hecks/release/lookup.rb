# frozen_string_literal: true

require "open3"

module Hecks
  module Release
    # Whether the GitHub Release of a tag exists, told apart from a lookup that failed.
    #
    # `gh release view` exits nonzero both when the release is missing and when the call itself
    # fails (rate limit, outage). Only GitHub's own words "release not found" mean absence; every
    # other answer is a failed lookup, retried and then named, never read as "not released".
    # It needs only the standard library, so `release.yml` runs it on the runner.
    module Lookup
      ABSENT = "release not found"
      ATTEMPTS = 3
      FOUND = 0
      # Not 1: a Ruby that dies (a helper that cannot load, an exception) exits 1, and that must
      # never read as "no release".
      MISSING = 10
      FAILED = 2

      module_function

      # @param status [Integer] the exit status of `gh release view`
      # @param output [String] what it printed, stderr included
      # @return [Symbol] :found, :absent or :failed
      def verdict(status:, output:)
        return :found if status.zero?

        output.to_s.downcase.include?(ABSENT) ? :absent : :failed
      end

      # Asks `gh` for the release of a tag.
      #
      # @param tag [String] such as "v7.1.0"
      # @return [Array(Integer, String)] exit status and output
      def gh(tag)
        out, status = Open3.capture2e("gh", "release", "view", tag)
        [status.exitstatus, out]
      end

      # @param tag [String] the release tag
      # @param runner [#call] returns [status, output] for a tag
      # @param out [#puts] where a failure is named
      # @param sleeper [#call] waits the given seconds between attempts
      # @return [Integer] 0 when the release exists, 10 when it does not, 2 when the lookup failed
      def check(tag, runner: method(:gh), out: Kernel, sleeper: ->(seconds) { sleep(seconds) })
        ATTEMPTS.times do |attempt|
          last = attempt_verdict(runner, tag)
          return code(last) unless last == :failed

          sleeper.call(5 * (attempt + 1)) if attempt < ATTEMPTS - 1
        end
        out.puts("::error::release lookup failed for #{tag}: GitHub did not say whether it exists")
        FAILED
      end

      # @return [Symbol] the verdict of one try; a runner that raises (no `gh`) is :failed
      def attempt_verdict(runner, tag)
        verdict(**named(runner.call(tag)))
      rescue StandardError
        :failed
      end

      # @return [Hash] the runner's answer as verdict keywords
      def named(answer) = { status: answer[0], output: answer[1] }

      # @return [Integer] the exit status for a settled verdict
      def code(verdict) = verdict == :found ? FOUND : MISSING
    end
  end
end
