# frozen_string_literal: true

module Hecks
  module Adapters
    # The verdict an architect's closing text states: `sound`, `changes` (for "sound with changes")
    # or `rethink`. The adapter that closes a review and the board that lists it read it alike.
    module ArchitectVerdict
      # The words a verdict is one of, found anywhere in the text when no Verdict line is.
      WORDS = /\b(sound with changes|sound|rethink)\b/i

      # The line the architect is asked to end its closing message with; the last one wins. It may
      # be set in bold, quoted, or end with a period.
      LINE = /^[\s*_`>#-]*verdict:\s*[*_`]*(sound with changes|sound|rethink)\b/i

      # The format the verdict reader expects, stated in the architect's brief. A job keeps only the
      # tail of what the architect wrote last, so the verdict goes on the last line.
      REQUEST = "\n\nWhen you finish, make the last line of your closing message exactly " \
                "`Verdict: sound`, `Verdict: sound with changes` or `Verdict: rethink`."

      # @param text [String] what the architect wrote last
      # @return [String] `sound`, `changes`, `rethink`, or empty when the text states none
      def self.of(text)
        word = (text.scan(LINE).last&.first || text[WORDS, 1]).to_s.downcase
        word == "sound with changes" ? "changes" : word
      end
    end
  end
end
