# frozen_string_literal: true

module Hecks
  module Adapters
    class SubmittedPaths
      # Matches each changed path to the `ReviewTier` and `SecurityWord` rows of the Agents
      # bluebook's ChangeReview aggregate and answers the tier the rows give. It holds no class or
      # word of its own: the rule is the `Tier` query's, stated beside the rows.
      class ReviewTiering
        FLAGS = File::FNM_PATHNAME | File::FNM_DOTMATCH
        # What a path's words are split at: `/`, `.`, `_` and `-`.
        WORD_BREAK = %r{[/._-]}

        # @param tiers [Array<Hash>] the `ReviewTier` rows
        # @param words [Array<Hash>] the `SecurityWord` rows
        def initialize(tiers:, words:)
          @tiers = tiers
          @words = words.map { |row| row[:word] }
        end

        # @param changes [Array<Array(String, Boolean)>] each changed path, and whether git reports
        #   it as an end of a pure rename
        # @param regenerated [String] `same` when regenerating gave the same bytes
        # @return [String] the tier, then one `<tier> <class> <path>` line per path
        def answer(changes, regenerated)
          lines = changes.map { |path, renamed| [*classify(path, renamed, regenerated), path] }
          tier = lines.empty? || lines.any? { |line| line.first == "full" } ? "full" : "verify_only"
          [tier, *lines.map { |line| line.join(" ") }].join("\n")
        end

        # @return [Array(String, String)] the path's tier and class
        def classify(path, renamed, regenerated)
          return %w[full security] if security?(path)

          rows = named(path, renamed)
          return %w[full unnamed] if rows.empty?

          held(rows, regenerated) || ["verify_only", rows.map { |row| row[:kind] }.join("+")]
        end

        private

        # The first row that makes the path full: a full row, else a verify_only row unproven.
        def held(rows, regenerated)
          full = rows.find { |row| row[:tier] == "full" }
          return ["full", full[:kind]] if full

          unproven = rows.find { |row| !proven?(row, regenerated) }
          ["full", "#{unproven[:kind]}-unproven"] if unproven
        end

        def security?(path) = path.downcase.split(WORD_BREAK).intersect?(@words)

        def named(path, renamed)
          @tiers.select do |row|
            (renamed && row[:proof] == "pure_rename") || row[:paths].split.any? { |glob| File.fnmatch?(glob, path, FLAGS) }
          end
        end

        def proven?(row, regenerated)
          row[:proof] != "regenerated" || regenerated == "same"
        end
      end
    end
  end
end
