require "find"

module Hecksagain
  class Bluebook
    # Finds domain declaration folders without loading or executing them.
    class ProjectDiscovery
      SKIPPED_DIRECTORIES = %w[.git .bundle data node_modules target tmp vendor generated coverage].freeze

      attr_reader :root

      def initialize(root)
        @root = File.expand_path(root)
      end

      def bluebook_directories
        found = []
        Find.find(root) do |path|
          if File.directory?(path)
            if SKIPPED_DIRECTORIES.include?(File.basename(path))
              Find.prune
            elsif File.basename(path) == "bluebook" && Dir.glob(File.join(path, "*.bluebook")).any?
              found << path
            end
          end
        end
        found.sort
      end
    end
  end
end
