# frozen_string_literal: true

require_relative "git_worktrees"

module Hecks
  module Adapters
    # The `Committing` port's adapter for `Commit`: stages the named paths, then commits what is
    # staged under the message, on the branch the checkout is on.
    #
    # It never pushes, never amends, never forces, and never commits onto `main`: that goes through
    # `Landing`, and a push goes through `PushTrain`. A commit with nothing staged is declined.
    class GitCommit
      include GitWorktrees

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @git = Git.new
      end

      # Commits what is staged in a checkout, after staging the named paths when there are some.
      #
      # @param held [Hash] the `Commit` record: `checkout` (a directory inside the worktree; the
      #   current directory when absent), `message`, and `paths` (whitespace-separated, optional)
      # @return [Hash{Symbol => Hash}] `sha:` the commit made, `report:` what it says
      # @raise [ConsoleCapture::Failure] on an empty message, a commit onto `main`, nothing staged,
      #   or a directory outside a repository
      def commit(**held)
        settle(held)
        message = plain(held[:message]).to_s.strip
        raise ConsoleCapture::Failure, "a commit needs a message" if message.empty?

        branch = current_branch
        raise ConsoleCapture::Failure, "a commit onto main goes through Landing" if branch == "main"

        stage(plain(held[:paths]))
        refuse_nothing_staged
        read("commit", "-m", message)
        sha = read("rev-parse", "--short", "HEAD")
        { sha: { value: sha }, report: { value: "committed #{sha} on #{branch}" } }
      end

      private

      # Stages each named path; `--` keeps a path from being read as an option.
      def stage(paths)
        names = paths.to_s.split
        read("add", "--", *names) unless names.empty?
      end

      def refuse_nothing_staged
        return unless read("diff", "--cached", "--name-only").empty?

        raise ConsoleCapture::Failure, "nothing is staged to commit"
      end
    end
  end
end
