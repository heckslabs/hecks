# frozen_string_literal: true

module Hecks
  module Adapters
    class OutputBrief
      # The first error line of every failed example in what a spec run printed.
      #
      # The test runner prints each failure as a numbered block: `N) description`, then
      # `Failure/Error: <source>`, a blank line and the message. A failure the runner printed
      # without that shape (a file that did not load) yields the first line of its block. The
      # lines are numbered `N. ` so that a summary read again does not look like a runner's block.
      # At most `limit` failures are listed; the rest are counted.
      class FailureErrors
        HEADER = /^\s*\d+\) (?<name>\S.*)$/
        ENDING = /^Finished in |^Failed examples:/
        SOURCE = %r{^\s*Failure/Error:}

        # @param lines [Array<String>] what the run printed, one entry per line
        # @param limit [Integer] the most failures listed
        def initialize(lines, limit)
          @lines = lines
          @limit = limit
        end

        # @return [String, nil] the `Errors:` section, or nil when no failure block was printed
        def to_s
          found = entries
          return if found.empty?

          listed = found.first(@limit).each_with_index.map { |(name, error), at| "  #{at + 1}. #{name}: #{error}" }
          listed << "  (#{found.size - @limit} more in the file)" if found.size > @limit
          (["Errors:"] + listed).join("\n")
        end

        private

        # @return [Array<Array(String, String)>] each failure's description and first error line
        def entries
          blocks.map { |name, body| [name, message(body)] }
        end

        # Each failure block's description and lines. A block ends at the next header or at the
        # runner's closing lines, so several files' reports in one text each count.
        def blocks
          current = nil
          @lines.each_with_object([]) do |line, found|
            header = HEADER.match(line)
            current = nil if ENDING.match?(line)
            header ? found << (current = [header[:name], []]) : current&.last&.push(line)
          end
        end

        # The message line: the first line after the source of `Failure/Error:`, else the first
        # line of the block.
        def message(body)
          at = body.index { |line| SOURCE.match?(line) }
          lines = at ? body.drop(at + 1).drop_while { |line| !line.strip.empty? } : body
          lines.map(&:strip).find { |line| !line.empty? && !line.start_with?("# ") } || "(no message)"
        end
      end
    end
  end
end
