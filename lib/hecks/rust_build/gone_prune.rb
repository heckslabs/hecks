# frozen_string_literal: true

require_relative "prune"

module Hecks
  module RustBuild
    # The part of {Prune} that takes only what a gone worktree left: the `target/` of a directory
    # under `.claude/worktrees` that git does not list and the slot its binary builds kept in the
    # shared target. A merged worktree that may hold a session, and the shared cache's stale
    # artifacts, are left to the full {Prune.run}.
    module GonePrune
      module_function

      # @param root [String] the hecks copy this runs from
      # @return [Boolean] whether a gone worktree left a build dir, found without sizing anything
      def any?(root: ROOT)
        listing = Worktrees.listing(root)
        live = Worktrees.paths(listing)
        shared = TargetDir.shared_root(root: root)
        orphan_targets(live).any? || Prune.abandoned_slots(shared, live).any?
      end

      # @param root [String] the hecks copy this runs from
      # @param dry_run [Boolean] report without deleting
      # @return [Integer] bytes freed (or that would be)
      def run(root: ROOT, dry_run: false)
        listing = Worktrees.listing(root)
        live = Worktrees.paths(listing)
        gone = Prune.targets_of(unlisted(live), dry_run: dry_run)
        gone + Prune.unlisted_slots(TargetDir.shared_root(root: root), live, dry_run: dry_run)
      end

      # @return [Array<String>] the `target/` directories of worktree directories git does not list
      def orphan_targets(live)
        unlisted(live).flat_map { |dir| Dir.glob(File.join(dir, "rust", "{,*/}target")) }
      end

      # @return [Array<String>] the directories under the main checkout's `.claude/worktrees` that
      #   git does not list
      def unlisted(live)
        dir = File.join(live.first, ".claude", "worktrees")
        File.directory?(dir) ? Prune.unlisted(dir, live) : []
      end
    end
  end
end
