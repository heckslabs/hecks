# frozen_string_literal: true

require "fileutils"
require_relative "target_dir"

module Hecks
  module RustBuild
    # Keeps Cargo's build output from growing without bound.
    #
    # Two things grow it: a `target/` left behind in a worktree that is gone, and stale compiled
    # artifacts piling up in a target that is still in use.
    module Prune
      module_function

      # Deletes the artifacts under each target's `<profile>/{deps,incremental,build}` not touched
      # for `days`.
      # @param targets [Array<String>] Cargo target directories
      # @param days [Integer] how long a file may sit unused
      # @param dry_run [Boolean] report without deleting
      # @return [Integer] bytes freed (or that would be)
      def stale(targets, days: 14, dry_run: false)
        cutoff = Time.now - (days * 86_400)
        targets.flat_map { |t| Dir.glob(File.join(t, "*", "{deps,incremental,build}", "*")) }
               .select { |path| File.mtime(path) < cutoff }
               .sum { |path| remove(path, dry_run) }
      end

      # Deletes the `target/` of every worktree directory git no longer lists.
      # @param worktrees_dir [String] directory holding worktrees
      # @param live [Array<String>] worktree paths git still lists
      # @return [Integer] bytes freed (or that would be)
      def orphans(worktrees_dir, live:, dry_run: false)
        Dir.children(worktrees_dir).map { |n| File.join(worktrees_dir, n) }
           .reject { |dir| live.include?(dir) }
           .then { |dirs| targets_of(dirs, dry_run: dry_run) }
      end

      # Deletes the `target/` inside each given worktree (a build is rebuilt on demand, so this
      # loses no work; the caller names only worktrees whose branch already landed).
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
