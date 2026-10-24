# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "reading"

module Hecks
  module Adapters
    class GitTrain
      # A detached worktree a push is made from, removed once it ends. The local branch is checked
      # out there and merged with the remote's when the two have parted, so the repository's
      # pre-push hook checks the very commit that goes out, not whatever a checkout holds.
      class Bench
        include Reading

        # What git says when the remote's branch moved after the fetch.
        MOVED = /\[rejected\]|non-fast-forward|fetch first|cannot lock ref|stale info/

        # How many lines of a refused push's output a refusal keeps.
        KEPT_LINES = 40

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param branch [String] the branch to push
        # @param remote [String] the remote to push it to
        def initialize(git, checkout, branch:, remote:)
          @git = git
          @checkout = checkout
          @branch = branch
          @remote = remote
        end

        # Pushes the local branch, merged with the remote's when they have parted.
        #
        # @param local [String] the commit the local branch names
        # @param tracking [String] the remote-tracking branch, just fetched
        # @return [String, Symbol] the commit pushed, or `:moved` when the remote's branch moved
        # @raise [ConsoleCapture::Failure] when the two conflict, or the push is refused
        def push(local, tracking)
          Dir.mktmpdir("hecks-push-train") do |scratch|
            bench = File.join(scratch, "bench")
            read("worktree", "add", "--quiet", "--detach", bench, local)
            push_from(bench, local, tracking)
          ensure
            @git.capture("worktree", "remove", "--force", bench, chdir: @checkout) if bench
          end
        end

        private

        def push_from(bench, local, tracking)
          merge(bench, tracking) unless ancestor?(tracking, local)
          pushed = @git.capture("push", @remote, "HEAD:refs/heads/#{@branch}", chdir: bench)
          return read("rev-parse", "HEAD", dir: bench) if pushed.ok?
          return :moved if pushed.err.match?(MOVED)

          raise ConsoleCapture::Failure, "the push of #{@branch} was refused:\n#{tail(pushed)}"
        end

        def merge(bench, tracking)
          return if @git.capture("merge", "--no-edit", tracking, chdir: bench).ok?

          conflicted = read("diff", "--name-only", "--diff-filter=U", dir: bench).split.join(", ")
          @git.capture("merge", "--abort", chdir: bench)
          raise ConsoleCapture::Failure,
                "#{@branch} and #{tracking} conflict in #{conflicted}: merge them by hand, then board again"
        end

        def tail(result) = "#{result.out}#{result.err}".lines.last(KEPT_LINES).join
      end
    end
  end
end
