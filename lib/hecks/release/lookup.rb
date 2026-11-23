# frozen_string_literal: true

require "open3"

module Hecks
  module Release
    # Whether the GitHub Release of a tag exists, told apart from a lookup that failed.
    #
    # `gh release view` exits nonzero both when the release is missing and when the call itself
    # fails (rate limit, outage). Only GitHub's own words "release not found" mean absence; every
    # other answer is a failed lookup, retried and then named, never read as "not released". Like
    # {Approval} it needs only the standard library, so `release.yml` runs it with the runner's Ruby.
    module Lookup
      ABSENT = "release not found"
      ATTEMPTS = 3
      FOUND = 0
      MISSING = 1
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
      # @return [Integer] 0 when the release exists, 1 when it does not, 2 when the lookup failed
      def check(tag, runner: method(:gh), out: $stdout, sleeper: ->(seconds) { sleep(seconds) })
        last = nil
        ATTEMPTS.times do |attempt|
          last = verdict(**named(runner.call(tag)))
          return code(last) unless last == :failed

          sleeper.call(5 * (attempt + 1)) if attempt < ATTEMPTS - 1
        end
        out.puts("::error::release lookup failed for #{tag}: GitHub did not say whether it exists")
        FAILED
      end

      # @return [Hash] the runner's answer as verdict keywords
      def named(answer) = { status: answer[0], output: answer[1] }

      # @return [Integer] the exit status for a settled verdict
      def code(verdict) = verdict == :found ? FOUND : MISSING
    end
  end
end
