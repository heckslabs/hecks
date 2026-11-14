# frozen_string_literal: true

require "hecks/hecks/adapters/git_worktrees"
require_relative "../git_main_pull"

module Hecks
  module Adapters
    class GitLanding
      # The one step of a landing that moves a branch: a compare-and-swap. The branch goes from the
      # commit a landing started at to the commit it built, and only if it still points there.
      #
      # The move is `git update-ref` with the expected value, which git makes atomic, so of two
      # landings that started from one commit exactly one wins and the other is told it lost. It
      # takes no turn and waits for no landing. When a worktree has the branch checked out, that
      # worktree's files then follow the very step the branch took (`git read-tree -m -u`), which
      # touches only the paths the step changed; git has no single command that moves a branch and
      # its checked-out files together, and a fast-forward run by two landings at once leaves the
      # loser's files staged there.
      class Swap
        include GitWorktrees

        # Raised when the branch points somewhere other than where the landing started. Nothing
        # changed.
        class Lost < RuntimeError; end

        # How often a step is tried again while git's own lock file is held or the worktree's
        # files are still following an earlier landing.
        LOCK_TRIES = 20

        # Seconds between two of those tries.
        LOCK_PAUSE = 0.1

        # How git names a lock file another git process holds.
        LOCKED = /\.lock/

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param onto [String] the branch to move
        def initialize(git, checkout, onto:)
          @git = git
          @checkout = checkout
          @onto = ref(onto)
        end

        # @param before [String] the commit the branch pointed at when the landing started
        # @param candidate [String] the commit to move it to, a descendant of `before`
        # @return [String, nil] nil, or a sentence when the branch moved and the files of the
        #   worktree that holds it could not follow
        # @raise [Lost] when the branch moved meanwhile
        # @raise [ConsoleCapture::Failure] when the worktree that holds the branch has unsaved work
        #   or is midway through a rebase or merge, or git's own lock on the branch never cleared
        def move(before, candidate)
          host = worktree_on(@onto)
          settle(host.path, before) if host
          update(before, candidate)
          follow(host.path, before, candidate) if host
        end

        private

        # Waits out an earlier landing whose files are still following, then refuses a worktree
        # that still holds changed files: those are unsaved work.
        def settle(dir, before)
          refuse_midway(dir)
          changed = []
          LOCK_TRIES.times do
            raise Lost, "#{@onto} moved from #{short(before)}" unless branch_tip(@onto) == before
            return if (changed = dirty(dir)).empty?

            sleep(LOCK_PAUSE)
          end
          raise ConsoleCapture::Failure, unsaved_refusal(dir, changed)
        end

        def update(before, candidate)
          LOCK_TRIES.times do
            result = @git.capture("update-ref", "refs/heads/#{@onto}", candidate, before, chdir: @checkout)
            return if result.ok?
            raise Lost, "#{@onto} moved from #{short(before)}" unless branch_tip(@onto) == before
            raise ConsoleCapture::Failure, refusal(result) unless result.err.match?(LOCKED)

            sleep(LOCK_PAUSE)
          end
          raise ConsoleCapture::Failure, "git's own lock on #{@onto} did not clear in #{@checkout}; nothing changed"
        end

        # Brings the worktree's index and files along the step the branch took. A try that meets
        # git's index lock, or paths an earlier landing's step has not written yet, is made again.
        def follow(dir, before, candidate)
          result = nil
          LOCK_TRIES.times do
            result = @git.capture("read-tree", "-m", "-u", before, candidate, chdir: dir)
            return nil if result.ok?

            sleep(LOCK_PAUSE)
          end
          left_behind(dir, before, candidate, result)
        end

        def left_behind(dir, before, candidate, result)
          "#{@onto} moved, but the files in #{dir} did not follow (#{first_words(result)}): " \
            "run `git -C #{dir} read-tree -m -u #{short(before)} #{short(candidate)}`"
        end

        # The first line of what git said when it failed.
        def first_words(result)
          said = result.err.strip.lines
          said.first.to_s.strip
        end

        def refuse_midway(dir)
          midway = GitMainPull::MIDWAY.find { |name, _| File.exist?(git_path(dir, name)) }
          raise ConsoleCapture::Failure, "#{dir} is in the middle of a #{midway.last}; nothing changed" if midway
        end

        def git_path(dir, name) = read("rev-parse", "--path-format=absolute", "--git-path", name, dir: dir)

        def refusal(result) = "git would not move #{@onto}: #{result.err.strip}; nothing changed"
      end
    end
  end
end
