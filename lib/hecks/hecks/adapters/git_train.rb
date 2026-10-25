# frozen_string_literal: true

require_relative "git"
require_relative "console_capture"
require_relative "git_train/reading"
require_relative "git_train/bench"
require_relative "git_train/local_branch"
require_relative "git_train/carriage"
require_relative "git_train/survey"

module Hecks
  module Adapters
    # The `Train` port's adapter: pushes a checkout's branch one push at a time per repository.
    #
    # A boarding takes an exclusive `flock` on a file in the repository's common git directory, so
    # every worktree of one repository waits in the same line, and holds it until its push ends.
    # Waiting costs nothing: the pre-push checks of one push run at a time instead of all at once.
    class GitTrain
      include Reading

      # The lock's file, in the repository's common git directory.
      LOCK_FILE = "hecks-push-train.lock"

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @git = Git.new
      end

      # Waits for the push ahead in the same repository, then carries the boarded commit.
      #
      # @param held [Hash] the `PushTrain` record: `branch`, `remote`, `checkout` (a directory
      #   inside the repository; the current directory when none is named) and `full_gate` (the
      #   push runs the whole pre-push stage, which the hook reads from `HECKS_PRE_PUSH_GATE`)
      # @return [Hash{Symbol => Hash}] `outcome:` (`pushed` or `carried`), `checkout:`, `boarded:`,
      #   `pushed:` and `report:`
      # @raise [ConsoleCapture::Failure] when the checkout is not a repository, the branch and the
      #   remote's conflict, or the push is refused
      def carry(**held)
        @checkout = toplevel(plain(held[:checkout]) || Dir.pwd)
        carriage = Carriage.new(@git, @checkout, branch:   plain(held[:branch]) || "main",
                                                 remote:   plain(held[:remote]) || "origin",
                                                 hook_env: hook_env(held))
        boarded = carriage.local_head
        in_turn { carriage.carry(boarded) }
      end

      # Lists every checkout under a directory whose default branch has commits its remote does
      # not, fetching each first.
      #
      # @param held [Hash] the `PushTrain` record: `checkout` (the directory whose children are
      #   surveyed; the current directory when none is named) and `remote`
      # @return [Hash{Symbol => Hash}] `report:` one line per checkout with unpushed commits
      # @raise [ConsoleCapture::Failure] when the directory does not exist
      def tally(**held)
        root = plain(held[:checkout]) || Dir.pwd
        raise ConsoleCapture::Failure, "#{root} is not a directory" unless File.directory?(root)

        { report: { value: Survey.new(@git, root, remote: plain(held[:remote]) || "origin").report } }
      end

      private

      # A git hook takes no arguments, so the argument reaches the pre-push hook as the variable it
      # reads, for this push only.
      def hook_env(held) = plain(held[:full_gate]) == true ? { "HECKS_PRE_PUSH_GATE" => "1" } : {}

      def in_turn
        path = File.join(read("rev-parse", "--path-format=absolute", "--git-common-dir"), LOCK_FILE)
        File.open(path, File::RDWR | File::CREAT) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def toplevel(dir)
        raise ConsoleCapture::Failure, "#{dir} is not a directory" unless File.directory?(dir)

        read("rev-parse", "--show-toplevel", dir: dir)
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
