require "open3"

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

      # A `Hecks.bluebook "Name"` header line, capturing the chapter's name.
      CHAPTER_HEADER = /\A\s*Hecks\.bluebook\s+"([^"]+)"/

      # A line number: digits and nothing else.
      LINE_NUMBER = /\A\d+\z/

      # A message ending in `(expected one of: a, b)`, capturing the message and the list.
      EXPECTED_SUFFIX = /\A(.*) \(expected one of: (.*)\)\z/

      # Raised when no `hecks-parse` binary can be found.
      class ParserMissing < StandardError; end

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
      # @return [String, nil] the name its `Hecks.bluebook "Name"` header declares
      def chapter_name(path)
        File.foreach(path) { |line| return Regexp.last_match(1) if line =~ CHAPTER_HEADER }
        nil
      end

      # @api private
      def refusal_for(stage, chapter, files)
        paths = files.map { |relative| File.join(stage, relative) }
        _out, err, status = Open3.capture3(binary, "chapter", "--chapter", chapter, *paths)
        return nil if status.success?

        first_line = err.lines.first
        diagnostic(first_line.to_s.chomp, stage)
      end

      # Reads `<file>:<line>: <message>` with an optional `(expected one of: a, b, c)` suffix.
      # @api private
      def diagnostic(line, stage)
        rest = line.delete_prefix("#{stage}/")
        file, number, message = rest.split(":", 3)
        return { file: nil, line: nil, message: line, expected: [] } unless number.to_s.strip.match?(LINE_NUMBER)

        message = message.to_s.strip
        expected = []
        if (found = message.match(EXPECTED_SUFFIX))
          message = found[1]
          expected = found[2].split(", ")
        end
        { file: file, line: number.to_i, message: message, expected: expected }
      end

      # @return [String] the path to `hecks-parse`: `HECKS_PARSE_BIN`, then the release or debug
      #   build under `rust/parser/target/`
      # @raise [ParserMissing] if none exists
      def binary
        candidates = [ENV.fetch("HECKS_PARSE_BIN", nil)] +
                     %w[release debug].map { |profile| File.join(ROOT, "rust/parser/target/#{profile}/hecks-parse") }
        candidates.compact.find { |path| File.executable?(path) } or
          raise ParserMissing, "hecks-parse is not built — run `cargo build --release " \
                               "--manifest-path rust/parser/Cargo.toml`"
      end
    end
  end
end
