# frozen_string_literal: true

require "fileutils"
require_relative "../console_capture"
require_relative "train"
require_relative "prefix_boarding/local_files"

module Hecks
  module Adapters
    class MainIntegration
      # Boards the good prefix of main: the commits before a named culprit, so what is good ships
      # while the culprit is reverted. The push train's copy follows main on every beat, so its
      # shape files differ from the prefix's and the train refuses to board it. The boarding is
      # instead run from a detached worktree at the prefix, which then is the launcher whose shape
      # is the boarded commit's. The worktree carries the checkout's machine-local world files and
      # runs cold (`HECKS_NO_RESIDENT=1`). The command line is {Train}'s fixed one: no plain push,
      # no force, no skipped hook, no owner override. It decides nothing: whether to revert is the
      # domain's rule.
      class PrefixBoarding
        # Where the prefix worktrees are kept, beside the checkouts.
        BASE = File.join(Dir.home, "Projects", "hecks-worktrees")

        # The environment variable that keeps the launcher from using a resident process.
        COLD = "HECKS_NO_RESIDENT=1"

        # The statuses of a boarding that has left nothing for the worktree to do.
        DONE = %w[pushed carried].freeze

        # @param repository [Repository] the repository whose main holds the culprit
        # @param runner [#call] takes `(argv, chdir:)` and answers `[ok, output]`
        # @param base [String] the directory the worktree is made in
        def initialize(repository, runner:, base: BASE)
          @repository = repository
          @runner = runner
          @base = File.expand_path(base)
        end

        # @param culprit [String] the named culprit's commit
        # @return [Hash{String => Object}] the train's record, with `"worktree"` the path kept for
        #   a queued boarding (removed with {#retire} once the train merges), nil otherwise
        # @raise [ConsoleCapture::Failure] when the culprit has no parent, the worktree's place is
        #   taken, a git step failed, or the train did not push; the worktree is removed first
        def board(culprit)
          prefix = @repository.first_parent(culprit) or fail!("#{culprit[0, 10]} has no parent to board")
          directory = add(prefix, culprit)
          record = boarding(directory, prefix)
          kept = DONE.include?(record["status"].to_s) ? retire(directory) : directory
          record.merge("worktree" => kept, "prefix" => prefix)
        rescue ConsoleCapture::Failure
          retire(directory) if directory
          raise
        end

        # Removes a prefix worktree; one already gone is left as it is.
        #
        # @param directory [String] the worktree's path
        # @return [nil]
        def retire(directory)
          git("worktree", "remove", "--force", directory) if File.exist?(directory)
          nil
        end

        private

        def boarding(directory, prefix)
          Train.new(cold, root: directory).board(directory, commit: prefix)
        end

        # The runner with the cold launch said for the launcher's own command only.
        def cold
          lambda do |argv, chdir:|
            @runner.call(argv.first.to_s.end_with?("exe/hecks") ? ["env", COLD, *argv] : argv, chdir: chdir)
          end
        end

        def add(prefix, culprit)
          directory = File.join(@base, "prefix-board-#{culprit[0, 10]}")
          fail!("#{directory} is taken; remove it first") if File.exist?(directory)
          FileUtils.mkdir_p(@base)
          git("worktree", "add", "--detach", directory, prefix)
          LocalFiles.new(@repository.checkout).copy_to(directory)
          directory
        end

        def git(*args)
          ok, said = @runner.call(["git", *args], chdir: @repository.checkout)
          fail!("git #{args.first(2).join(" ")}: #{said.to_s.strip[-200..] || said}") unless ok
        end

        def fail!(why) = raise(ConsoleCapture::Failure, "prefix boarding: #{why}")
      end
    end
  end
end
