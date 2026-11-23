# frozen_string_literal: true

require "fileutils"
require "hecks/cache_dir"

module Hecks
  module Adapters
    class MainIntegration
      # The one commit the release cut made, remembered so a boarding may carry its version change.
      #
      # The `ReleaseCutting` adapter records the sha of the bump commit it made; the boarding guard
      # accepts a change to the version file only on that exact commit. A commit message cannot say
      # it: only a process with the cache directory can.
      module ReleaseCutMark
        module_function

        # @return [String] the file the mark is kept in
        def path = File.join(Hecks::CacheDir.path("release"), "cut-commit")

        # @param sha [String] the bump commit the release cut made
        # @return [void]
        def record(sha)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, "#{sha}\n")
        end

        # @param sha [String] the tip of a range about to be boarded
        # @return [Boolean] whether it is the commit the release cut made
        def cut?(sha) = File.exist?(path) && File.read(path).strip == sha.to_s
      end
    end
  end
end
