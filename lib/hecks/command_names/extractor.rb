module Hecks
  module CommandNames
    # The launcher invocations in a file's text: where each is, and the words typed after the launcher.
    class Extractor
      # One invocation found.
      Call = Struct.new(:line, :text, :words)

      # `exe/hecks` names the launcher wherever it appears.
      STRONG = %r{exe/hecks(?=\s)\s+(?<rest>[^`"'|;&)>\\]*)}
      # `exe/hecks` as the head of an argument list.
      LISTED = %r{exe/hecks["']\s*,\s*["'](?<rest>[^"']*)}
      # A bare `hecks` counts when a backtick opens it, or a prompt precedes it.
      QUOTED = /(?<=`)hecks\s+(?<rest>[^`"'|;&)>\\]*)/
      PROMPT = /(?:\A|\s)\$\s+hecks\s+(?<rest>[^`"'|;&)>\\]*)/
      # A bare `hecks` that opens a line of shell, in a fence or a shell file.
      SHELL = /\A\s*(?:bundle exec\s+)?hecks\s+(?<rest>[^`"'|;&)>\\]*)/

      # A word that can be a launcher name, with the punctuation prose puts after it cut off.
      NAME = /\A[A-Za-z_][\w:]*(?:\.\w+)*!?\z/

      # The line marker that excuses an illustrative invocation, on its own line or the one before.
      MARKER = "dead-name-check: skip".freeze

      # @param shell [Boolean] whether a line may open with a bare `hecks` (a fence, a shell file)
      # @param strong_only [Boolean] whether only `exe/hecks` counts, as in a code comment's prose
      def initialize(shell: false, strong_only: false)
        @shell = shell
        @strong_only = strong_only
      end

      # @param line [String] one line of text
      # @param number [Integer] its line number
      # @return [Array<Call>] the invocations on it
      def calls(line, number)
        return [] unless line.include?("hecks")

        patterns.flat_map { |pattern| line.scan(pattern).flatten }.filter_map { |rest| call(rest, number, line) }
      end

      private

      def patterns
        return [STRONG, LISTED] if @strong_only

        [STRONG, LISTED, QUOTED, PROMPT, (SHELL if @shell)].compact
      end

      def call(rest, number, line)
        words = words(rest)
        Call.new(number, line.strip, words) unless words.empty?
      end

      # The leading words of a line that spell a launcher name, after the flags before it.
      def words(rest)
        tokens = rest.split.drop_while { |token| token.start_with?("-") }
        tokens.map { |token| token.sub(/[,.;:)\]]+\z/, "") }.take_while { |token| token.match?(NAME) }.first(3)
      end
    end
  end
end
