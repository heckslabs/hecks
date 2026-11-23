# frozen_string_literal: true

module Hecks
  module Clients
    # A pasted meeting transcript, read into turns. Pure: it reads text and answers data.
    module Transcript
      # A turn's header in a Zoom saved transcript: `[Speaker] 09:00:05`.
      HEADER = /\A\[(?<speaker>[^\]]*\S[^\]]*)\]\s+(?<at>\d{1,2}:\d{2}:\d{2})\s*\z/

      # Reads a chunk of a Zoom saved transcript into its turns, in the order said. The words of a
      # turn are the lines under its header, joined by a space. Words before any header are the
      # tail of a turn cut by the chunk boundary and come back as a turn with no speaker or time. A
      # turn with no words is left out. The time stays the clock string Zoom wrote.
      #
      # @param text [String] a pasted chunk
      # @return [Array<Hash>] turns as `{ speaker:, at:, text: }`
      def self.turns(text)
        lines(text).each_with_object([]) { |line, turns| add(turns, line) }
                   .reject { |turn| turn[:text].empty? }
      end

      # @param text [String] a pasted chunk
      # @return [Array<String>] its lines without blanks
      def self.lines(text)
        stripped = text.to_s.lines.map(&:strip)
        stripped.reject(&:empty?)
      end

      # Puts a line on the turns: a header opens one, any other line joins the last.
      #
      # @param turns [Array<Hash>] the turns so far
      # @param line [String] the next line
      # @return [void]
      def self.add(turns, line)
        header = HEADER.match(line)
        turns << opened(header) if header || turns.empty?
        return if header

        turns.last[:text] = [turns.last[:text], line].reject(&:empty?).join(" ")
      end

      # @param header [MatchData, nil] a matched header, nil for words before any header
      # @return [Hash] an empty turn for the header
      def self.opened(header)
        { speaker: header&.[](:speaker)&.strip, at: header&.[](:at), text: "" }
      end
    end
  end
end
