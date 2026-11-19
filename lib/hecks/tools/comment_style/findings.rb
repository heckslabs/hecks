# frozen_string_literal: true

require_relative "../../tools"
require_relative "file_cache"

module Hecks
  module Tools
    module CommentStyle
      # The violations of a set of Ruby files, read from each file's {FileFacts}: the cache
      # supplies the facts of a file whose text it has seen, and the baseline, the category filter
      # and the check across files (a type reopened in several files) are applied to them here,
      # over the whole set, on every run.
      class Findings
        # @param files [Array<String>] the Ruby files, in order
        # @param cache [FileCache, FileCache::None] where each file's facts come from
        # @param baseline [Hash{String => Hash{String => Integer}}] the long blocks to tolerate
        def initialize(files, cache:, baseline:)
          @files = files
          @cache = cache
          @baseline = baseline
        end

        # @return [Array<Violation>] every file's violations, then each undocumented type
        def violations
          facts = @files.to_h { |path| [path, @cache.facts(path)] }
          @cache.save!
          facts.flat_map { |path, held| held.violations(path, @baseline) } + undocumented_types(facts)
        end

        private

        # A type reopened across files counts as documented if any opening is.
        def undocumented_types(facts)
          openings = facts.flat_map { |path, held| held.types.map { |fqn, line, documented| [path, fqn, line, documented] } }
          openings.group_by { |opening| opening[1] }.filter_map { |fqn, group| undocumented_opening(fqn, group) }
        end

        def undocumented_opening(fqn, group)
          return unless CommentStyle.public_surface.include?(fqn.to_s.split("::").last)
          return if group.any?(&:last)

          path, _, line = group.first
          Violation.new(path, line, "undocumented_class", fqn)
        end
      end
    end
  end
end
