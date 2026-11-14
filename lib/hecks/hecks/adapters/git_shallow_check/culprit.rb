# frozen_string_literal: true

module Hecks
  module Adapters
    class GitShallowCheck
      # Reads what a red run said: the spec files that failed and the message of the first failure.
      class Culprit
        # A failed example in the summary, by line or by quoted id, or a spec file left unloaded.
        SPEC_FILE = %r{^rspec '?\./(spec/\S+?_spec\.rb)|loading \./(spec/\S+?_spec\.rb)}

        # The line that opens a failure, the one that opens its backtrace, and the blank line
        # between its expression and its message.
        OPENING = %r{Failure/Error:}
        BACKTRACE = /\A\s*# /
        PARAGRAPH_BREAK = /\n\s*\n/

        # A line naming what went wrong in a run that printed no failure block.
        ERROR = /Error/

        # The longest reason a refusal carries.
        LIMIT = 300

        # @param text [String] what the run wrote
        def initialize(text)
          @text = text
        end

        # @return [String] `<spec>, <spec>: <reason>`
        def to_s = "#{specs.empty? ? "the check set" : specs.join(", ")}: #{reason}"

        # @return [Array<String>] every spec file with a failed example, or that would not load
        def specs = @text.scan(SPEC_FILE).map { |found| found.compact.first }.uniq

        # The first failure's message: what was expected and what came, or the error raised. A run
        # with no failure block answers its first error line, else the last line it wrote.
        #
        # @return [String] one line, at most `LIMIT` characters
        def reason
          said = message || expression || lines.grep(ERROR).first || lines.last.to_s
          said.length > LIMIT ? "#{said[0, LIMIT]}..." : said
        end

        private

        def lines = @text.lines.map(&:strip).reject(&:empty?)

        # The first failure block: from its opening line to its backtrace.
        def block
          opened = @text.lines.drop_while { |line| !line.match?(OPENING) }
          opened.take_while { |line| !line.match?(BACKTRACE) }.join
        end

        # The block as one-line paragraphs: the expression, then the message.
        def paragraphs
          parts = block.split(PARAGRAPH_BREAK)
          parts.map { |part| part.split.join(" ") }.reject(&:empty?)
        end

        def message = present(paragraphs.drop(1).join(" "))

        def expression
          opened = paragraphs.first.to_s
          present(opened.sub(OPENING, "").strip)
        end

        def present(said) = said.empty? ? nil : said
      end
    end
  end
end
