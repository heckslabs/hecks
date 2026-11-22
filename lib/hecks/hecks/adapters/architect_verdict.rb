# frozen_string_literal: true

module Hecks
  module Adapters
    # The verdict an architect's closing text states: `sound`, `changes` (for "sound with changes"),
    # `rethink`, or `unverified` when the review ends on that line. The adapter that closes a
    # review and the board that lists it read it alike.
    module ArchitectVerdict
      # The words a verdict is one of, found anywhere in the text when no Verdict line is.
      WORDS = /\b(sound with changes|sound|rethink|unverified)\b/i

      # The line the architect is asked to end its closing message with; the last one wins. It may
      # be set in bold, quoted, or end with a period.
      LINE = /^[\s*_`>#-]*verdict:\s*[*_`]*(sound with changes|sound|rethink|unverified)\b/i

      # The format the verdict reader expects, stated in the architect's brief. A job keeps only the
      # tail of what the architect wrote last, so the verdict goes on the last line.
      REQUEST = "\n\nWhen you finish, make the last line of your closing message exactly " \
                "`Verdict: sound`, `Verdict: sound with changes` or `Verdict: rethink`; " \
                "when you read no diff and no file, `Verdict: unverified`."

      # @param text [String] what the architect wrote last
      # @return [String] `sound`, `changes`, `rethink`, `unverified`, or empty when none is stated
      def self.of(text)
        word = (text.scan(LINE).last&.first || text[WORDS, 1]).to_s.downcase
        word == "sound with changes" ? "changes" : word
      end
    end
  end
end
