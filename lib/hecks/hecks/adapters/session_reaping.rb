# frozen_string_literal: true

require_relative "shell"
require_relative "console_capture"
require_relative "claude_cleaning/worktree_check"
require_relative "dispatching/work_items"
require_relative "landing/worktree_scratch"

module Hecks
  module Adapters
    # What the bluebook needs to know to remove a finished run's session in the right order: the
    # facts that decide it, the clearing of the world's scratch list, and the retiring of the
    # worktree.
    #
    # It decides nothing. Whether the Work is still open, whether the run produced a product, and
    # whether the worktree holds work to lose are returned as facts; the `AgentRun` policies keep
    # or go on. Retiring uses {GitLanding}'s own guard, the one `Landing.retire!` makes.
    class SessionReaping
      # The world verb that carries the scratch list and the keep time.
      VERB = "reaping"

      # Work statuses that mean the Work item is not finished or dropped.
      OPEN = %w[planned started].freeze

      # @param registry [Runtime::Registry, nil] whose Tickets, Agents and world are read
      # @param check [ClaudeCleaning::WorktreeCheck] reads a worktree's files and commits
      # @param shell [Shell] runs `git`
      def initialize(registry:, check: ClaudeCleaning::WorktreeCheck.new, shell: Shell.new)
        @registry = registry
        @check = check
        @shell = shell
        @items = Dispatching::WorkItems.new(registry)
      end

      # @param held [Hash] the `AgentRun` record: `run`, `work`, `agent`
      # @param path [String, nil] the worktree the session's transcript recorded
      # @return [Hash{Symbol => Object}] `work_open:`, `no_product:`, `worktree:` (empty when none
      #   stands), `dirty:` (a file not committed and not ignored) and `unmerged:` (a commit origin
      #   lacks)
      def facts(held, path)
        tree = path.to_s
        tree = "" unless File.directory?(tree)
        { work_open: open?(held), no_product: no_product?(held), worktree: tree, **state(tree) }
      end

      # Clears the scratch the world lists in a worktree, and only that.
      #
      # @param path [String] the worktree's directory
      # @return [Hash{Symbol => Object}] `note:` what was cleared and what was left
      def clear(path)
        done = WorktreeScratch.new(globs: Array(settings[:worktree_scratch]).map(&:to_s), shell: @shell).clear(path)
        { note: "cleared #{done[:cleared].length} scratch path(s)#{kept_words(done[:kept])}" }
      end

      # Removes a worktree and deletes its branch, once the branch is on `main`.
      #
      # @param path [String] the worktree's directory
      # @return [Hash{Symbol => Object}] `note:` what the retirement reported
      # @raise [ConsoleCapture::Failure] when the worktree holds anything that would be lost
      def retire(path)
        require_relative "git_landing"
        branch = @shell.capture("git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD").out.strip
        said = GitLanding.new(registry: @registry).remove(checkout: path, branch: branch, onto: "main")
        { note: "worktree retired: #{said.dig(:report, :value)}" }
      end

      # @return [Hash{Symbol => Object}] the world's `reaping` line, empty when it declares none
      def settings = @registry&.world("Hecks")&.for_verb(VERB) || {}

      private

      def open?(held) = OPEN.include?(@items.work_status(work_key(held)))

      def work_key(held)
        work = plain(held[:work]).to_s
        work.empty? ? plain(held[:run]).to_s : work
      end

      def no_product?(held)
        role = plain(held[:agent]).to_s
        role = plain(held[:works_as]).to_s if role.empty?
        @items.no_product_roles.include?(role)
      end

      def state(tree)
        return { dirty: false, unmerged: false } if tree.empty?

        { dirty: @check.uncommitted(tree).positive?, unmerged: @check.ahead(tree).positive? }
      end

      def kept_words(kept) = kept.empty? ? "" : "; left #{kept.join(", ")}"

      def plain(value) = value.is_a?(Hash) ? value.transform_keys(&:to_s)["value"] : value
    end
  end
end
