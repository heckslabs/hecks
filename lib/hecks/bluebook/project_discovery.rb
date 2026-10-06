require "find"

module Hecks
  module Bluebook
    # Finds domain declaration folders without loading or executing them.
    class ProjectDiscovery
      SKIPPED_DIRECTORIES = %w[.git .bundle data node_modules target tmp vendor generated coverage].freeze

      attr_reader :root

      # @param root [String] the directory to search under
      def initialize(root)
        @root = File.expand_path(root)
      end

      # Walks `root` for every directory that holds `.bluebook` files.
      #
      # @return [Array<String>] the absolute path of each `bluebook` directory found,
      #   sorted; a directory named in `SKIPPED_DIRECTORIES` is pruned from the walk
      def bluebook_directories
        found = []
        Find.find(root) do |path|
          next unless File.directory?(path)

          Find.prune if SKIPPED_DIRECTORIES.include?(File.basename(path))
          found << path if bluebook_directory?(path)
        end
        found.sort
      end

      private

      def bluebook_directory?(path)
        File.basename(path) == "bluebook" && Dir.glob(File.join(path, "*.bluebook")).any?
      end
    end
  end
end
