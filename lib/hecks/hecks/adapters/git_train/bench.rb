# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "reading"

module Hecks
  module Adapters
    class GitTrain
      # A detached worktree a push is made from, removed once it ends. The boarded commit is checked
      # out there and pushed by its own id, so the repository's pre-push hook checks the very commit
      # that goes out, not whatever a checkout or a moving branch holds.
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
        # @param config [Array<String>] `-c name=value` words placed before `push`, which the
        #   repository's pre-push hook reads with `git config`
        def initialize(git, checkout, branch:, remote:, config: [])
          @git = git
          @checkout = checkout
          @branch = branch
          @remote = remote
          @config = config
        end

        # Pushes one commit to the remote's branch, as it is.
        #
        # @param local [String] the commit to push
        # @param tracking [String] the remote-tracking branch, just fetched
        # @return [String, Symbol] the commit pushed, or `:moved` when the remote's branch moved
        # @raise [ConsoleCapture::Failure] when the commit is not built on the remote's branch, or
        #   the push is refused
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
          diverged!(local, tracking) unless ancestor?(tracking, local)
          carry = ["-c", "hecks.trainCarry=#{local}"]
          pushed = @git.capture(*@config, *carry, "push", @remote, "#{local}:refs/heads/#{@branch}", chdir: bench)
          return local if pushed.ok?
          return :moved if pushed.err.match?(MOVED)

          raise ConsoleCapture::Failure, "the push of #{@branch} was refused:\n#{tail(pushed)}"
        end

        # A commit not built on the remote's branch would need a merge, which would
        # push a commit nobody minted for or settled: it is refused.
        def diverged!(local, tracking)
          raise ConsoleCapture::Failure,
                "#{tracking} moved since #{short(local)} was settled: it is not built on it; board again"
        end

        def tail(result) = "#{result.out}#{result.err}".lines.last(KEPT_LINES).join
      end
    end
  end
end
