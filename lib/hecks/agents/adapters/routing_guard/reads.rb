# frozen_string_literal: true

module Hecks
  module Adapters
    class RoutingGuard
      # What the guard reads from the text of a launcher call: the spans the shell reads as literal,
      # and whether the call only reads (a query, or a request for `--help`).
      module Reads
      # A span the chaining check reads past, scanned left to right: a backslash pair outside
      # quotes first, so an escaped quote opens no span, then a single- or double-quoted span.
      QUOTED = /\\.|'[^']*'|"(?:\\.|[^"\\])*"/m
      # What the shell still runs inside double quotes; `${x:-$(y)}` is caught by its `$(`.
      SUBSTITUTION = /`|\$\(/

      private

      # Whether a launcher call only reads, for every role in every domain: it asks for `--help`, or
      # names a query. The launcher refuses a command written without its `!`, so a verb with no
      # `!` writes nothing.
      def read?(text)
        call = unquoted(text).sub(LAUNCHER, "")
        return true if call.split.include?("--help")

        word = call.split.find { |candidate| candidate.match?(VERB_WORD) }
        !word.nil? && !word.end_with?("!")
      end

      # The text with each quoted span blanked, so a `;` the shell reads as literal is not chaining.
      # A backslash pair stays, a double-quoted span holding a substitution stays, and an unclosed
      # quote matches no span and so stays too.
      def unquoted(text)
        text.gsub(QUOTED) do |span|
          next span unless span.start_with?("'", '"')

          span.start_with?('"') && span.match?(SUBSTITUTION) ? span : span[0] * 2
        end
      end
      end
    end
  end
end
