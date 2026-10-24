module Hecks
  module Corpus
    # Where `.adapter` files live, for the parser parity check. Extended onto `Corpus`.
    module Adapters
      # Directories that hold copies or build output, never a source `.adapter`.
      EXCLUDED_DIRS = %w[vendor node_modules target tmp .git .aws-sam].freeze

      ADAPTER_GLOBS = %w[lib/**/*.adapter examples/**/*.adapter spec/fixtures/**/*.adapter].freeze

      # Every `.adapter` file the repo carries.
      #
      # @param root [String] repository root to search under
      # @return [Array<String>] absolute paths, sorted, none under a vendored, `node_modules`,
      #   `target` or scratch directory
      def adapter_files(root: Corpus::ROOT)
        found = ADAPTER_GLOBS.flat_map { |glob| Dir.glob(File.join(root, glob)) }.uniq.sort
        found.reject do |path|
          path.delete_prefix("#{root}/").split("/").intersect?(EXCLUDED_DIRS)
        end
      end
    end
  end
end
