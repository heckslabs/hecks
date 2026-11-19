# frozen_string_literal: true

module Hecks
  module Adapters
    # The judgment a reviewer's closing text states: `real_bug`, `stale_expectation`, or `landed`
    # when the branch landed before the review ran.
    module ReviewerJudgment
      # The words a judgment is one of.
      WORDS = /\b(real[ _]bug|stale[ _]expectation|landed)\b/i

      # The last word named wins: the report ends with its judgment, and may name `landed` or a
      # judgment word in passing before it.
      #
      # @param text [String] what the reviewer wrote last
      # @return [String] `real_bug`, `stale_expectation`, `landed`, or empty when the text names
      #   none
      def self.of(text)
        named = text.scan(WORDS).flatten
        named.empty? ? "" : named.last.downcase.tr(" ", "_")
      end
    end
  end
end
