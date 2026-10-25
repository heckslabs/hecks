# frozen_string_literal: true

require_relative "git"
require_relative "console_capture"
require_relative "git_train/reading"

module Hecks
  module Adapters
    # What the `Checkout` and `Landing` adapters share: finding a repository from any directory in
    # it, listing its worktrees, and telling a clean tree from a dirty one.
    #
    # An includer sets `@git` (the `Git` adapter) before calling anything here, and `settle` sets
    # `@checkout` (a repository's top level). Every branch or ref that reaches a command is
    # checked against `GitRefs::REF_PATTERN` first, so a name cannot carry a flag.
    module GitWorktrees
      include GitTrain::Reading

      # One worktree of a repository, as `git worktree list --porcelain` describes it.
      #
      # @!attribute [r] path
      #   @return [String] where it is checked out
      # @!attribute [r] head
      #   @return [String, nil] the commit it stands on
      # @!attribute [r] branch
      #   @return [String, nil] the branch it has checked out, nil when detached
      Worktree = Struct.new(:path, :head, :branch)

      # The blank line between two worktrees in `git worktree list --porcelain`.
      BLOCK_BREAK = /\n\n+/

      private

      # Points the adapter at the repository a directory is in.
      #
      # @param held [Hash] the arguments of a command or query; `checkout` names the directory
      # @return [String] the repository's top level
      # @raise [ConsoleCapture::Failure] when the directory is not there or not in a repository
      def settle(held)
        dir = plain(held[:checkout]) || Dir.pwd
        raise ConsoleCapture::Failure, "#{dir} is not a directory" unless File.directory?(dir)

        @checkout = read("rev-parse", "--show-toplevel", dir: dir)
      end

      def worktrees
        read("worktree", "list", "--porcelain").split(BLOCK_BREAK).map { |block| worktree_of(block) }
      end

      def worktree_of(block)
        fields = block.lines.to_h { |line| line.strip.split(" ", 2).then { |key, value| [key, value] } }
        Worktree.new(fields["worktree"], fields["HEAD"], fields["branch"]&.delete_prefix("refs/heads/"))
      end

      def primary = worktrees.first

      def worktree_on(branch) = worktrees.find { |tree| tree.branch == branch }

      def current_branch
        result = @git.capture("symbolic-ref", "--quiet", "--short", "HEAD", chdir: @checkout)
        return result.out.strip if result.ok?

        raise ConsoleCapture::Failure, "#{@checkout} has no branch checked out"
      end

      # The paths git lists as changed or untracked in a tree, one porcelain line each.
      def dirty(dir = @checkout) = read("status", "--porcelain", dir: dir).lines.map(&:rstrip)

      def ref(name)
        return name if name.to_s.match?(GitRefs::REF_PATTERN)

        raise ConsoleCapture::Failure, "#{name.inspect} is not a branch or ref name"
      end

      def branch_tip(branch) = read("rev-parse", "--verify", "refs/heads/#{ref(branch)}^{commit}")

      def count(range) = read("rev-list", "--count", range).to_i

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
