# frozen_string_literal: true

require "fileutils"
require_relative "target_dir"
require_relative "worktrees"

module Hecks
  module RustBuild
    # Keeps Cargo's build output from growing without bound.
    #
    # Two things grow it: a `target/` left behind in a worktree that is gone or has landed, and
    # stale compiled artifacts piling up in a target that is still in use.
    module Prune
      # How long a cached artifact may sit unused.
      DAYS = 14

      module_function

      # Frees what a checkout's builds hold: the `target/` of worktrees that are gone or merged,
      # then the shared cache's stale artifacts.
      #
      # @param root [String] the hecks copy this runs from
      # @param days [Integer] how long a cached artifact may sit unused
      # @param dry_run [Boolean] report without deleting
      # @return [Integer] bytes freed (or that would be)
      def run(root: ROOT, days: DAYS, dry_run: false)
        listing = Worktrees.listing(root)
        shared = TargetDir.shared_root(root: root)
        freed = worktree_targets(listing, root, dry_run) + unlisted_slots(shared, Worktrees.paths(listing), dry_run: dry_run)
        freed + stale(shared_targets(shared), days: days, dry_run: dry_run)
      end

      # @return [Integer] bytes freed (or that would be) from the `target/` of worktrees git no
      #   longer lists and of those whose branch landed
      def worktree_targets(listing, root, dry_run)
        dir = File.join(Worktrees.paths(listing).first, ".claude", "worktrees")
        gone = File.directory?(dir) ? orphans(dir, live: Worktrees.paths(listing), dry_run: dry_run) : 0
        gone + targets_of(Worktrees.merged(listing, running: root), dry_run: dry_run)
      end

      # @param shared [String] the directory every shared target lives in
      # @return [Array<String>] the shared directory itself, which is a target when sessions build
      #   there directly, and each directory in it: a worktree's own, or a crate's from before
      def shared_targets(shared) = [shared] + Dir.glob(File.join(shared, "*")).select { |path| File.directory?(path) }

      # How long a worktree's slot must sit untouched before it can be deleted.
      SLOT_GRACE_DAYS = 1

      # Deletes the directory a worktree's binary builds kept in the shared target, once its
      # worktree is gone. A slot stays when git lists a worktree by its name (spelled as given or
      # as the file system spells it), when the checkout it records as its owner still exists
      # (another clone of hecks sharing the directory, say), or when anything in it changed within
      # the last day.
      # @param shared [String] the directory every shared target lives in
      # @param live [Array<String>] worktree paths git still lists
      # @param now [Time] the time the grace period counts from
      # @return [Integer] bytes freed (or that would be)
      def unlisted_slots(shared, live, dry_run: false, now: Time.now)
        names = live.flat_map { |path| SessionBuild.slugs(path) }
        slots = Dir.glob(File.join(shared, "*-#{"[0-9a-f]" * 8}")).select { |path| File.directory?(path) }
        abandoned = slots.reject { |path| names.include?(File.basename(path)) || kept?(path, now) }
        abandoned.sum { |path| remove(path, dry_run) }
      end

      # @return [Boolean] whether a slot git does not list still has an owner or recent work
      def kept?(slot, now)
        owner = owner_of(slot)
        return true if owner && File.exist?(owner)

        newest_change(slot) > now - (SLOT_GRACE_DAYS * 86_400)
      end

      # @return [String, nil] the checkout the slot records as its owner
      def owner_of(slot)
        file = File.join(slot, SessionBuild::OWNER)
        File.file?(file) ? File.read(file).strip : nil
      rescue SystemCallError
        nil
      end

      # @return [Time] the latest modification time of anything in the slot, the slot included
      def newest_change(slot)
        times = entries_of(slot).map { |path| File.mtime(path) }
        [*times, File.mtime(slot)].max
      rescue SystemCallError
        Time.now
      end

      # @return [Array<String>] everything inside the slot, hidden files included
      def entries_of(slot) = Dir.glob(File.join(slot, "**", "*"), File::FNM_DOTMATCH)

      # Deletes the artifacts under each target's `<profile>/{deps,incremental,build}` not touched
      # for `days`.
      # @param targets [Array<String>] Cargo target directories
      # @param days [Integer] how long a file may sit unused
      # @param dry_run [Boolean] report without deleting
      # @return [Integer] bytes freed (or that would be)
      def stale(targets, days: DAYS, dry_run: false)
        cutoff = Time.now - (days * 86_400)
        artifacts = targets.flat_map { |t| Dir.glob(File.join(t, "*", "{deps,incremental,build}", "*")) }
        artifacts.select { |path| File.mtime(path) < cutoff }.sum { |path| remove(path, dry_run) }
      end

      # Deletes the `target/` of every worktree directory git does not list.
      # @param worktrees_dir [String] directory holding worktrees
      # @param live [Array<String>] worktree paths git still lists
      # @return [Integer] bytes freed (or that would be)
      def orphans(worktrees_dir, live:, dry_run: false)
        targets_of(unlisted(worktrees_dir, live), dry_run: dry_run)
      end

      # @return [Array<String>] the directories under `worktrees_dir` not in `live`
      def unlisted(worktrees_dir, live)
        Dir.children(worktrees_dir).map { |name| File.join(worktrees_dir, name) } - live
      end

      # Deletes the `target/` inside each given worktree. Cargo rebuilds it on demand, so this
      # loses no work; the caller names only worktrees whose branch already landed.
      # @param worktrees [Array<String>] worktree directories
      # @return [Integer] bytes freed (or that would be)
      def targets_of(worktrees, dry_run: false)
        worktrees.flat_map { |dir| Dir.glob(File.join(dir, "rust", "{,*/}target")) }
                 .sum { |path| remove(path, dry_run) }
      end

      # @return [Integer] bytes the path held
      def remove(path, dry_run)
        bytes = size(path)
        FileUtils.rm_rf(path) unless dry_run
        bytes
      end

      def size(path)
        return File.size(path) unless File.directory?(path)

        Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).sum { |f| File.file?(f) ? File.size(f) : 0 }
      end
    end
  end
end
