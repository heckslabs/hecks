# frozen_string_literal: true

module Hecks
  module Adapters
    # What a plan review keeps of the architect's closing message: the message whole when it is
    # at most 60000 characters, else its head and its tail with a marker naming what was cut. The
    # head holds the verdict's reason and the first finding, the tail the last finding and the
    # Verdict line;
    # the coder brief quotes each finding, so neither end may be lost. The adapter that closes a
    # review and the board that lists it keep it alike.
    module ArchitectFindings
      # The characters kept from the start: the verdict's reason and the first findings.
      HEAD = 50_000

      # The characters kept from the end: the last finding and the Verdict line.
      TAIL = 10_000

      # @param whole [String] the closing message read whole from the session's transcript
      # @param tail [String] what the job keeps of it, read when the transcript holds none
      # @return [String] the first of the two that says something, or empty
      def self.pick(whole, tail)
        whole.to_s.strip.empty? ? tail.to_s : whole.to_s
      end

      # @param text [String] the architect's closing message
      # @return [String] the text whole when it is at most `HEAD + TAIL` characters, else its first
      #   `HEAD` and last `TAIL` characters with a marker between them naming how many were left out
      def self.clip(text)
        return text if text.length <= HEAD + TAIL

        "#{text[0, HEAD]}\n#{marker(text.length)}\n#{text[-TAIL..]}"
      end

      # @param length [Integer] the length of the whole text
      # @return [String] the line that says how much was kept, how much was cut and where the cut
      #   part is: the architect session's transcript, which is the only place that holds it
      def self.marker(length)
        "[… findings cut at #{HEAD + TAIL} of #{length} characters; the middle #{length - HEAD - TAIL} " \
          "are in the architect session's transcript …]"
      end
    end
  end
end
