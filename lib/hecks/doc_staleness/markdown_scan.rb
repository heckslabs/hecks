require_relative "finding"
require_relative "path_citation"
require_relative "constant_index"
require_relative "sources"

module Hecks
  module DocStaleness
    # A doc's backticked repo paths, held against the checkout. Fenced blocks are shown text and
    # are left alone, as is a line marked `staleness-check: skip`.
    class MarkdownScan
      SPAN = /`([^`\n]+)`/

      # @param root [String] the checkout
      # @param path [String] the doc, relative to `root`
      # @param text [String] its text
      # @param _index [ConstantIndex] unused: a doc's constants are not read
      def initialize(root, path, text, _index = nil)
        @root = root
        @path = path
        @lines = text.lines
      end

      # @return [Array<Finding>] each backticked path that names nothing, with its line
      def findings
        fenced = false
        @lines.each_with_index.flat_map do |line, index|
          fenced = !fenced if line.lstrip.start_with?("```")
          fenced || Sources.marked?(@lines, index) ? [] : on_line(line, index + 1)
        end
      end

      private

      def gone(line)
        spans = line.scan(SPAN).flatten
        spans.flat_map { |span| PathCitation.missing(span, @root) }.uniq
      end

      def on_line(line, number)
        gone(line).map do |path|
          Finding.new(@path, number, "doc-path", "`#{path}` does not exist")
        end
      end
    end
  end
end
