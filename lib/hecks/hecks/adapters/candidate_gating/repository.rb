# frozen_string_literal: true

require_relative "../console_capture"
require_relative "../candidate_gate"

module Hecks
  module Adapters
    class CandidateGating
      # The repository a candidate request reads and moves: its git directory, where local and
      # remote main stand, the candidate ref, and the worktree that holds main.
      class Repository
        # The remote the candidate and main live on.
        REMOTE = "origin"

        # The branch a merge commit's subject names.
        MERGED_BRANCH = /Merge branch '([^']+)'/

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] a directory inside the repository
        def initialize(git, checkout)
          @git = git
          @checkout = checkout
        end

        # @return [String] the repository's top level
        def top = read("rev-parse", "--show-toplevel")

        # @return [String] the repository's common git directory
        def git_dir = read("rev-parse", "--path-format=absolute", "--git-common-dir")

        # Brings the remote-tracking main and candidate up to the remote.
        #
        # @return [void]
        def fetch
          read("fetch", "--quiet", REMOTE, "+refs/heads/main:refs/remotes/#{remote_main}")
          @git.capture("fetch", "--quiet", REMOTE, "+refs/heads/#{CandidateGate::BRANCH}:refs/remotes/#{remote_candidate}",
                       chdir: @checkout)
        end

        # @param ref [String] a branch or commit
        # @return [String, nil] the full commit it names, nil when it names none
        def commit(ref)
          done = @git.capture("rev-parse", "--verify", "--quiet", "#{ref}^{commit}", chdir: @checkout)
          done.ok? ? done.out.strip : nil
        end

        # @return [Boolean] whether `ancestor` is reachable from `descendant`
        def ancestor?(ancestor, descendant) = @git.ancestor?(ancestor, descendant, chdir: @checkout)

        # @return [String] the remote-tracking main
        def remote_main = "#{REMOTE}/main"

        # @return [String] the remote-tracking candidate
        def remote_candidate = "#{REMOTE}/#{CandidateGate::BRANCH}"

        # @param base [String] the commit the range starts after
        # @param tip [String] the commit it ends at
        # @return [Array<String>] the commits in the range, newest first
        def commits(base, tip) = read("rev-list", "#{base}..#{tip}").split("\n").reject(&:empty?)

        # @return [Array<String>] the distinct authors of the range, in first-seen order
        def authors(base, tip) = read("log", "--format=%an", "#{base}..#{tip}").split("\n").reject(&:empty?).uniq

        # @return [Array<String>] the branches the range's merge commits name
        def branches(base, tip)
          read("log", "--merges", "--format=%s", "#{base}..#{tip}").scan(MERGED_BRANCH).flatten.uniq
        end

        # @return [String, nil] the worktree that has main checked out, nil when none has
        def main_worktree
          blocks = read("worktree", "list", "--porcelain").split("\n\n")
          held = blocks.find { |block| block.lines.map(&:chomp).include?("branch refs/heads/main") }
          held && worktree_path(held)
        end

        # The path a porcelain worktree block opens with.
        def worktree_path(block)
          first = block.lines.first.chomp
          first.delete_prefix("worktree ")
        end

        # @param worktree [String] a worktree
        # @return [Boolean] whether it holds no changed tracked file
        def clean?(worktree) = read("status", "--porcelain", "--untracked-files=no", dir: worktree).empty?

        # Runs one git command in the repository and answers what it printed.
        #
        # @param args [Array<String>] the git subcommand and its arguments
        # @param dir [String] the directory to run in; the checkout by default
        # @return [String] standard output, stripped
        # @raise [ConsoleCapture::Failure] when git refused
        def read(*args, dir: @checkout)
          result = @git.capture(*args, chdir: dir)
          raise ConsoleCapture::Failure, "git #{args.first} failed in #{dir}: #{result.err.strip}" unless result.ok?

          result.out.strip
        end
      end
    end
  end
end
