# frozen_string_literal: true

module Hecks
  module Adapters
    class SubmittedPaths
      # Maps each changed path to the domains it touches by the `DomainPath` rows of the Agents
      # bluebook's ChangeReview aggregate. It reads only the checkout's directories: which bluebook
      # sits above a path, and which domains have a `.behaviors` file.
      class DomainOwners
        FLAGS = File::FNM_PATHNAME | File::FNM_DOTMATCH
        BEHAVIORS = "{lib,examples}/**/*.behaviors"

        # @param rows [Array<Hash>] the `DomainPath` rows, first match wins
        # @param root [String] the checkout the paths are read in
        def initialize(rows:, root:)
          @rows = rows
          @root = root
        end

        # @param paths [Array<String>] the changed paths
        # @return [String] one domain directory per line, sorted
        def answer(paths) = touched(paths).join("\n")

        private

        def touched(paths) = paths.flat_map { |path| owned(path) }.uniq.sort

        def owned(path)
          row = @rows.find { |candidate| candidate[:paths].split.any? { |glob| File.fnmatch?(glob, path, FLAGS) } }
          return [] unless row
          return every if row[:maps_to] == "every"

          owner = owner_of(File.dirname(path))
          owner ? [owner] : every
        end

        def owner_of(dir)
          until [".", "/"].include?(dir)
            return named(dir) if bluebook_in?(dir)

            dir = File.dirname(dir)
          end
        end

        def bluebook_in?(dir) = Dir.glob(["*.bluebook", "bluebook/*.bluebook"], base: File.join(@root, dir)).any?

        # A `bluebook/` folder names its parent: the domain is the directory that holds it.
        def named(dir) = File.basename(dir) == "bluebook" ? File.dirname(dir) : dir

        def every
          @every ||= Dir.glob(BEHAVIORS, base: @root).map { |file| named(File.dirname(file)) }.uniq
        end
      end
    end
  end
end
