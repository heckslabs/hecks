# frozen_string_literal: true

require "fileutils"
require_relative "boot_cache"
require_relative "rust_build/target_dir"

module Hecks
  # The rebuildable caches one hecks checkout keeps outside itself: its Cargo slot below the
  # shared target and its compiled-Ruby cache. Removing a checkout removes them too, since nothing
  # else would ever read them again.
  module CheckoutCaches
    module_function

    # Names the checkout's caches while it still exists, so the caller can remove them once the
    # checkout is gone.
    #
    # @param root [String] a hecks checkout
    # @return [Array<String>] the cache directories that belong to it and exist
    def of(root)
      (RustBuild::TargetDir.slots_of(root) + BootCache.dirs_of(root).select { |dir| File.directory?(dir) }).uniq
    end

    # @param dirs [Array<String>] cache directories {.of} named
    # @return [Array<String>] the directories removed
    def remove(dirs)
      dirs.each { |dir| FileUtils.rm_rf(dir) }
    end
  end
end
