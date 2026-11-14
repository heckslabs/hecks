# frozen_string_literal: true

module Hecks
  module Adapters
    class OutputBrief
      # The summary of what a spec run printed: where the full text is, the first failure, every
      # failed example by its location, and the counts.
      #
      # It reads the text the test runner and `Codebase::SpecFiles::Report` print, and
      # `spec/adapters/driven/output_brief_spec.rb` pins it to a real run of both. Every
      # `rspec ./path:line # description` line and the closing counts are kept whole, because the
      # push rehearsal (`GitRehearsal::Impacted::SpecRun`) reads them from a launcher's answer.
      class SpecSummary
        FIRST = /^\s*1\) /
        AFTER_FIRST = /^\s*2\) |^Finished in |^Failed examples:/
        FRAME = /^\s+# /
        FAILED = /^rspec \S+/
        COUNTS = /^\d+ examples?, \d+ failures?/
        GREEN = /^\d+ examples?, 0 failures?$/
        TABLE = /^files:$/

        # @param text [String] what the run printed
        # @param path [String] the file that holds all of it
        # @param limits [Hash{Symbol => Integer}] `frames`, `block` and `head`
        def initialize(text, path, limits)
          @lines = text.lines.map(&:chomp)
          @path = path
          @limits = limits
        end

        # @return [String] the summary, ending as the full text does: with the counts
        def to_s
          ["full output: #{@path} (#{@lines.size} lines)", opening, failed, closing].compact.join("\n\n")
        end

        private

        # The first failure, or the text's opening lines for a red run that printed no failure.
        def opening
          start = @lines.index { |line| FIRST.match?(line) }
          return capped(trimmed(block(start)), :block) if start

          capped(@lines, :head) unless green?
        end

        def green? = counts.to_s.match?(GREEN)

        def block(start)
          rest = @lines.drop(start + 1)
          [@lines[start], *rest.first(rest.index { |line| AFTER_FIRST.match?(line) } || rest.size)]
        end

        # The block with its backtrace cut to the first `frames` lines.
        def trimmed(block)
          seen = 0
          kept = block.reject { |line| FRAME.match?(line) && (seen += 1) > @limits[:frames] }
          dropped = block.size - kept.size
          kept.pop while kept.last.to_s.empty? && kept.any?
          dropped.zero? ? kept : kept + ["     # (#{dropped} more frames in the file)"]
        end

        def capped(lines, limit)
          lines = lines.reverse.drop_while(&:empty?).reverse
          return lines.join("\n") if lines.size <= @limits[limit]

          [*lines.first(@limits[limit]), "(#{lines.size - @limits[limit]} more lines in the file)"].join("\n")
        end

        def failed
          listed = @lines.grep(FAILED).uniq
          (["Failed examples:"] + listed).join("\n") unless listed.empty?
        end

        # The per-file table, verdict and total a batch ends with, or the runner's own counts.
        def closing
          table = @lines.rindex { |line| TABLE.match?(line) }
          table ? @lines.drop(table).join("\n") : counts
        end

        def counts = @lines.reverse.find { |line| COUNTS.match?(line) }
      end
    end
  end
end
