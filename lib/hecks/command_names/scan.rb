require_relative "extractor"

module Hecks
  module CommandNames
    # One file read for launcher invocations, leaving out the ones marked as illustrative.
    class Scan
      # A fence whose opening line says its content is shown and not meant to run.
      EXCUSED_FENCE = /\b(?:skip|historical|illustrative)\b/

      # @param path [String] the file's path, relative to the checkout
      # @param text [String] its text
      def initialize(path, text)
        @path = path
        @lines = text.scrub.lines
        @markdown = path.end_with?(".md")
        @ruby = path.end_with?(".rb")
        @shell = !path.end_with?(".rb", ".md", ".bluebook")
      end

      # @return [Array<Extractor::Call>] the invocations, each as `calls` of the extractor
      def calls
        fence = nil
        @lines.each_with_index.flat_map do |line, index|
          fence = fence_after(fence, line)
          next [] if skipped?(line, index, fence)

          extractor(fence, line).calls(line, index + 1)
        end
      end

      private

      # The open fence after a line: nil outside one, else its opening line.
      def fence_after(fence, line)
        return fence unless @markdown && line.lstrip.start_with?("```")

        fence ? nil : line
      end

      def skipped?(line, index, fence)
        return true if line.lstrip.start_with?("```") || excused?(fence)

        [line, (@lines[index - 1] if index.positive?)].compact.any? { |text| text.include?(Extractor::MARKER) }
      end

      def excused?(fence) = fence && fence.match?(EXCUSED_FENCE)

      # A Ruby comment is prose, so only the launcher's path names a call in it.
      def extractor(fence, line)
        Extractor.new(shell: @shell || !fence.nil?, strong_only: @ruby && line.lstrip.start_with?("#"))
      end
    end
  end
end
