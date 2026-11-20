# frozen_string_literal: true

module Hecks
  module Adapters
    # The judgment a reviewer's closing line states: `clean`, `real_bug`, `stale_expectation`,
    # `missing_behavior`, or `landed` when the branch landed before the review ran. Only a last
    # non-empty line that is one of those words alone counts, so a finding that says "model_check
    # is clean" earlier in the report never decides the judgment.
    module ReviewerJudgment
      # The closing words, as the `SubmissionReview.Judge` given accepts them.
      WORDS = %w[clean real_bug stale_expectation missing_behavior landed].freeze

      # A closing line: one word, optionally in backticks, with spaces or underscores between parts.
      LINE = /\A`?(clean|real[ _]bug|stale[ _]expectation|missing[ _]behavior|landed)`?\.?\z/i

      # @param text [String] what the reviewer wrote last
      # @return [String] one of the closing words, or empty when the last line is not one alone
      def self.of(text)
        closing_line(text)[LINE, 1].to_s.downcase.tr(" ", "_")
      end

      # @param text [String] what the reviewer wrote last
      # @return [String] its last line that says something, stripped, or empty
      def self.closing_line(text)
        lines = text.to_s.lines.map(&:strip)
        lines.reject(&:empty?).last.to_s
      end
    end
  end
end
