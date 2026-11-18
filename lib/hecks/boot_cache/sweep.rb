# frozen_string_literal: true

require_relative "../boot_cache"
require_relative "../rust_build/prune"

module Hecks
  module BootCache
    # Keeps the compiled-Ruby caches from growing without bound.
    #
    # It deletes a checkout's directory once the checkout it records as its owner is gone, by the
    # same rule {RustBuild::Prune} applies to a Cargo slot; anything under the cache that is not a
    # checkout's directory (the one cache every checkout shared); and a directory that grew past
    # {CAP_BYTES}, which the next boot rebuilds cold. The checkout the sweep runs from keeps its
    # own directory, whatever its size. Another checkout's process may be reading the directory
    # the cap clears: Bootsnap reads a missing entry as a miss and compiles the file again.
    module Sweep
      # The most one checkout's directory may hold before a sweep clears it.
      CAP_BYTES = 1 << 30

      # The name a checkout's directory carries ({CheckoutSlug.slug}).
      SLUG = /-[0-9a-f]{8}\z/

      module_function

      # @param root [String] the checkout the sweep runs from, whose git lists the live worktrees
      #   and whose own directory is never cleared
      # @param cap_bytes [Integer] the most one directory may hold
      # @param dry_run [Boolean] report without deleting
      # @return [Integer] bytes freed (or that would be)
      def run(root: RustBuild::ROOT, cap_bytes: CAP_BYTES, dry_run: false)
        live = RustBuild::Worktrees.paths(RustBuild::Worktrees.listing(root))
        sweep(live: live, keep: root, cap_bytes: cap_bytes, dry_run: dry_run)
      end

      # @param live [Array<String>] worktree paths git still lists, the checkout's own first
      # @param keep [String] the checkout whose directory is never cleared
      # @param cap_bytes [Integer] the most one directory may hold
      # @param dry_run [Boolean] report without deleting
      # @return [Integer] bytes freed (or that would be)
      def sweep(live:, keep:, cap_bytes: CAP_BYTES, dry_run: false)
        kept = BootCache.dirs_of(keep)
        entries.reject { |dir| kept.include?(dir) }
               .select { |dir| doomed?(dir, live, cap_bytes) }
               .sum { |dir| RustBuild::Prune.remove(dir, dry_run) }
      end

      # @return [Array<String>] the directories under the cache
      def entries
        Dir.glob(File.join(BootCache.base, "*")).select { |path| File.directory?(path) }
      end

      # @return [Boolean] whether the directory is not a checkout's, its owner is gone, or it is
      #   past the cap
      def doomed?(dir, live, cap_bytes)
        return true unless File.basename(dir).match?(SLUG)

        abandoned?(dir, live) || RustBuild::Prune.size(dir) > cap_bytes
      end

      # @return [Boolean] whether the checkout the directory records is gone; a directory that
      #   records none is judged by whether anything in it changed within the slot grace
      def abandoned?(dir, live)
        owner = CheckoutSlug.owner_of(dir)
        return !RustBuild::Prune.owner_standing?(owner, live) if owner

        !RustBuild::Prune.recent_change?(dir, Time.now - (RustBuild::Prune::SLOT_GRACE_DAYS * 86_400))
      end
    end
  end
end
