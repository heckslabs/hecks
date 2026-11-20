require_relative "extractor"
require_relative "sources"

module Hecks
  module CommandNames
    # One Ruby or Rust host file read for the remedies its refusals name.
    #
    # A remedy is a launcher name a refusal tells its reader to run: a remedy word (`run`,
    # `re-run`, `with`, `use`, `try`, `then`, `see`) before `hecks <name>` or `exe/hecks <name>`.
    # In the Rust host any `exe/hecks <name>` counts too, since no other check reads that tree. A
    # program label (`program: "hecks run"`), a usage line and prose that only mentions the
    # launcher are not remedies. Comment lines are left out, as are lines marked
    # `dead-name-check: skip` (on the line or the one before) and the `Sources::ALLOWED_LINES`.
    class RemedyScan
      # A remedy word before the launcher's name, and the words typed after it.
      PHRASE = %r{\b(?:run|re-run|rerun|with|use|try|then|see)\s+`?(?:exe/)?hecks\s+(?<rest>[^`"'|;&)>\\]*)}i

      # The launcher's path, wherever it appears in a Rust host string.
      STRONG = %r{exe/hecks\s+(?<rest>[^`"'|;&)>\\]*)}

      # The opening of a comment line in either language.
      COMMENT = %r{\A\s*(?:#|//)}

      # @param path [String] the file's path, relative to the checkout
      # @param text [String] its text
      def initialize(path, text)
        @rust = path.end_with?(".rs")
        @lines = text.scrub.lines
      end

      # @return [Array<Extractor::Call>] each remedy found, with its line number and words
      def remedies
        @lines.each_with_index.flat_map do |line, index|
          next [] if skipped?(line, index)

          references(line).filter_map { |words| Extractor::Call.new(index + 1, line.strip, words) }
        end
      end

      private

      # The words of each reference on a line.
      def references(line)
        tails(line).map { |rest| Extractor.new.words(rest) }.reject(&:empty?)
      end

      # The text after the launcher's name, once for each reference on a line.
      def tails(line) = patterns.flat_map { |pattern| line.scan(pattern).flatten }.uniq

      def patterns = @rust ? [PHRASE, STRONG] : [PHRASE]

      def skipped?(line, index)
        return true if line.match?(COMMENT) || !line.include?("hecks") || Sources.allowed?(line)

        [line, (@lines[index - 1] if index.positive?)].compact.any? { |text| text.include?(Extractor::MARKER) }
      end
    end
  end
end
