require "open3"
require_relative "../sentence_form"

module Hecks
  module Composer
    # The fast stage of a check: the Rust parser's verdict on the staged bluebooks, which it gives
    # in milliseconds, before anything is loaded. It reports the first refusal only, with the
    # words that would have been accepted there.
    module Parse
      # The repository root, where the parser's build lands under `rust/parser/target/`.
      ROOT = File.expand_path("../../..", __dir__).freeze

      # A bluebook file's path.
      BLUEBOOK_FILE = /\.bluebook\z/

      # A line number: digits and nothing else.
      LINE_NUMBER = /\A\d+\z/

      # A column then the message, as the sentence form's refusals give them: `63: this is not`.
      COLUMN_PREFIX = /\A(\d+): (.*)\z/m

      # A message ending in `(expected one of: a, b)`, capturing the message and the list.
      EXPECTED_SUFFIX = /\A(.*) \(expected one of: (.*)\)\z/

      # Raised when no `hecks-parse` binary can be found.
      ParserMissing = SentenceForm::ParserMissing

      module_function

      # Parses every bluebook in a staged workspace, one chapter at a time.
      #
      # @param stage [String] a staged directory (see {Workspace.stage})
      # @return [Hash, nil] nil when everything parses; otherwise `{file:, line:, message:,
      #   expected:}` for the first refusal, with `file` relative to the stage
      # @raise [ParserMissing] if `hecks-parse` is not built
      def call(stage)
        bluebooks(stage).each do |chapter, files|
          refusal = refusal_for(stage, chapter, files)
          return refusal if refusal
        end
        nil
      end

      # @param stage [String] a staged directory
      # @return [Hash{String => Array<String>}] relative bluebook paths by the chapter their
      #   header names
      def bluebooks(stage)
        bluebook_files(stage).group_by { |relative| chapter_name(File.join(stage, relative)) }
                             .reject { |name, _| name.nil? }
      end

      # @api private
      def bluebook_files(stage) = Workspace.files(stage).grep(BLUEBOOK_FILE)

      # @param path [String] a bluebook file
      # @return [String, nil] the name its `Hecks.bluebook "Name"` or `Domain: name` header declares
      def chapter_name(path) = SentenceForm.chapter_name(path)

      # @api private
      def refusal_for(stage, chapter, files)
        paths = files.map { |relative| File.join(stage, relative) }
        _out, err, status = Open3.capture3(binary, "chapter", "--chapter", chapter, *paths)
        return nil if status.success?

        first_line = err.lines.first
        diagnostic(first_line.to_s.chomp, stage)
      end

      # Reads `<file>:<line>: <message>`, or `<file>:<line>:<column>: <message>` for a file written
      # as sentences, with an optional `(expected one of: a, b, c)` suffix.
      # @api private
      def diagnostic(line, stage)
        file, number, message = line.delete_prefix("#{stage}/").split(":", 3)
        return { file: nil, line: nil, column: nil, message: line, expected: [] } unless number.to_s.strip.match?(LINE_NUMBER)

        column, message = split_column(message.to_s.strip)
        message, expected = split_expected(message)
        { file: file, line: number.to_i, column: column, message: message, expected: expected }
      end

      # @param message [String] a diagnostic's text after the line number
      # @return [Array(Integer, String), Array(nil, String)] the column it names, and the rest
      def split_column(message)
        positioned = message.match(COLUMN_PREFIX)
        positioned ? [positioned[1].to_i, positioned[2]] : [nil, message]
      end

      # @param message [String] a diagnostic's text with its column taken off
      # @return [Array(String, Array<String>)] the message, and the phrases that would have fitted
      def split_expected(message)
        found = message.match(EXPECTED_SUFFIX)
        found ? [found[1], found[2].split(", ")] : [message, []]
      end

      # @return [String] the path to `hecks-parse`; see {SentenceForm.binary}
      # @raise [ParserMissing] if none exists
      def binary = SentenceForm.binary
    end
  end
end
