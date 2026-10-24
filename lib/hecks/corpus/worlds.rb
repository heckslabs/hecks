module Hecks
  module Corpus
    # Where `.world` files live, for the parser parity check. Extended onto `Corpus`.
    module Worlds
      WORLD_GLOBS = %w[lib/**/*.world examples/**/*.world qa/**/*.world spec/fixtures/**/*.world].freeze

      # Every `.world` file the repo carries.
      #
      # @param root [String] repository root to search under
      # @return [Array<String>] absolute paths, sorted, none under a vendored, `node_modules`,
      #   `target` or scratch directory
      def world_files(root: Corpus::ROOT)
        found = WORLD_GLOBS.flat_map { |glob| Dir.glob(File.join(root, glob)) }.uniq.sort
        found.reject do |path|
          path.delete_prefix("#{root}/").split("/").intersect?(Adapters::EXCLUDED_DIRS)
        end
      end
    end
  end
end
