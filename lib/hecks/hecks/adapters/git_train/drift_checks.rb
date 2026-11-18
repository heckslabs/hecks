# frozen_string_literal: true

require "open3"
require_relative "../console_capture"
require_relative "build_failure"
require_relative "train_env"

module Hecks
  module Adapters
    class GitTrain
      # The drift checks a settlement runs once the branch is settled, each in check mode in the
      # checkout: none rewrites a file. The first that finds drift refuses the boarding and names
      # the check and the end of what it printed. A check whose Cargo build failed before it could
      # compare refuses too, named as a failed build under the cargo it found, never as drift.
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
        # @param base [#[]] the environment the checks would otherwise inherit
        def initialize(checkout, guard, checks, base: ENV)
          @checkout = checkout
          @guard = guard
          @checks = checks
          @base = base
        end

        # @param settled [String] the commit the branch named as the checks began
        # @return [void]
        # @raise [ConsoleCapture::Failure] naming the first check that found drift or whose build
        #   failed
        def run(settled)
          @env = environment(settled)
          @checks.each do |argv|
            out = found(argv, settled) or next

            raise ConsoleCapture::Failure, refusal(argv.drop(2).join(" "), out)
          end
        end

        private

        # The caller's `PATH` with rustup's proxies first, and the train's mark. The codegen build
        # inside the launcher puts rustup first on its own; this makes the cargo a failed build is
        # reported under the one that build used.
        def environment(settled)
          path = { "PATH" => @base["PATH"] }.compact
          path.merge(RustBuild::Toolchain.environment(@base), TrainEnv.for(settled, @base))
        end

        # What a check printed when it failed, nil when it is clean.
        def found(argv, settled)
          out, status = Open3.capture2e(@env, *argv, chdir: @checkout)
          return if status.success?
          return out if @guard.head == settled

          out, status = Open3.capture2e(@env, *argv, chdir: @checkout)
          out unless status.success?
        end

        # Names a failed build as one, and anything else a check refused as drift.
        def refusal(check, out)
          build = BuildFailure.named(out, @env)
          return "#{check} could not compare: #{build}; this is not drift: #{tail(out)}" if build

          "#{check} found drift; regenerate and commit it first: #{tail(out)}"
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
