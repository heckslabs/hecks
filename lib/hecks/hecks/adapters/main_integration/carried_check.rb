# frozen_string_literal: true

require_relative "../git"
require_relative "../console_capture"
require_relative "../git_main_pull/boarding"

module Hecks
  module Adapters
    class MainIntegration
      # Whether `origin/main` already holds a landed commit, so verifying it answers nothing. It
      # holds it when the commit is an ancestor of `origin/main`, or when a train squash there
      # ("Train: main at <sha>", same tree as <sha>) was boarded from a commit that has it as an
      # ancestor or is it. Reads `origin/main` as last fetched; `Repository#refresh` fetches.
      class CarriedCheck
        include GitMainPull::Boarding

        REMOTE_MAIN = "origin/main"

        # @param checkout [String] a directory inside the repository
        def initialize(checkout)
          @checkout = checkout
          @git = Git.new
        end

        # @param landed [String] the full commit a run landed
        # @return [String, nil] which test matched, naming the commit that carries it; nil when
        #   `origin/main` as fetched does not hold it (or does not exist)
        def by(landed)
          return nil unless @git.capture("rev-parse", "--verify", "--quiet", REMOTE_MAIN, chdir: @checkout).ok?
          return "is contained in #{REMOTE_MAIN}" if ancestor?(landed, REMOTE_MAIN)

          boarded = boardings(range(landed)).find { |sha| ancestor?(landed, sha) }
          boarded && "carried by squash (train boarded #{boarded[0, 10]})"
        end

        private

        def range(landed) = "#{read("merge-base", landed, REMOTE_MAIN)}..#{REMOTE_MAIN}"

        def ancestor?(sha, ref) = @git.capture("merge-base", "--is-ancestor", sha, ref, chdir: @checkout).ok?

        def read(*args)
          done = @git.capture(*args, chdir: @checkout)
          raise ConsoleCapture::Failure, "git #{args.first}: #{done.err.strip}" unless done.ok?

          done.out.strip
        end
      end
    end
  end
end
