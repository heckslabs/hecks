# frozen_string_literal: true

module Hecks
  module Adapters
    # The judgment a reviewer's closing text states: `real_bug` or `stale_expectation`.
    module ReviewerJudgment
      # The words a judgment is one of.
      WORDS = /\b(real[ _]bug|stale[ _]expectation)\b/i

      # @param text [String] what the reviewer wrote last
      # @return [String] `real_bug`, `stale_expectation`, or empty when the text names none
      def self.of(text)
        text[WORDS, 1].to_s.downcase.tr(" ", "_")
      end
    end
  end
end
