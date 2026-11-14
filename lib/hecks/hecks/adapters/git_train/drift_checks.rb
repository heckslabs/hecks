# frozen_string_literal: true

require "open3"
require_relative "../console_capture"

module Hecks
  module Adapters
    class GitTrain
      # The drift checks a settlement runs once the branch is settled, each in check mode in the
      # checkout: none rewrites a file. The first that finds drift refuses the boarding and names
      # the check and the end of what it printed.
      #
      # The checks read the checkout's files, which a landing moves. A check that fails once the
      # branch has moved may have read half of each tree, so it is run once more and that run
      # decides. The pull request's own CI judges the carried commit exactly.
      class DriftChecks
        # How many lines of what a check printed a refusal keeps.
        KEPT_LINES = 3

        # @param checkout [String] the repository's top level, where each check runs
        # @param guard [BranchGuard] reads the commit the boarded branch names now
        # @param checks [Array<Array<String>>] the command line of each check
        def initialize(checkout, guard, checks)
          @checkout = checkout
          @guard = guard
          @checks = checks
        end

        # @param settled [String] the commit the branch named as the checks began
        # @return [void]
        # @raise [ConsoleCapture::Failure] naming the first check that found drift
        def run(settled)
          @checks.each do |argv|
            out = found(argv, settled) or next

            raise ConsoleCapture::Failure, "#{argv.drop(2).join(" ")} found drift; regenerate and commit it first: #{tail(out)}"
          end
        end

        private

        # What a check printed when it found drift, nil when it is clean.
        def found(argv, settled)
          out, status = Open3.capture2e(*argv, chdir: @checkout)
          return if status.success?
          return out if @guard.head == settled

          out, status = Open3.capture2e(*argv, chdir: @checkout)
          out unless status.success?
        end

        # The last lines of what a check printed, as one line.
        def tail(out)
          last = out.lines.last(KEPT_LINES)
          last.join.strip
        end
      end
    end
  end
end
