# frozen_string_literal: true

require "fileutils"
require_relative "../../../cache_dir"
require_relative "../../../adapters/driving/usage_cache"

module Hecks
  module Adapters
    module Codebase
      # Empties the on-disk caches, which is how a cache is ruled out as the cause of a surprise.
      #
      # Only the user's cache directories go; the tables a packaged gem ships are not under
      # `CacheDir` and are never touched.
      module CacheClearing
        # The `Hecks::CacheDir` subdirectories it empties.
        DIRECTORIES = %w[hecks_syntax_boot_cache hecks_verdict_cache].freeze

        module_function

        # @return [String] which caches were emptied
        def clear
          cleared = DIRECTORIES.select do |name|
            path = Hecks::CacheDir.path(name)
            File.directory?(path) && FileUtils.rm_rf(path)
          end
          cleared << "usage" if Hecks::Adapters::Driving::UsageCache.clear
          cleared.empty? ? "no cache to clear" : "cleared #{cleared.join(", ")}"
        end
      end
    end
  end
end
