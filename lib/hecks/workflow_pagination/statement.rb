module Hecks
  module WorkflowPagination
    # One GitHub API call written in a workflow: the line it starts on and its text, with the lines
    # a trailing backslash joins, and the lines around it that say what it is used for.
    class Statement
      # What the call is for, read from the lines around it.
      Setting = Struct.new(:before, :after)

      # How far around a call the lines that say what it is for reach.
      REACH = 6

      # A GitHub API path: the part after the host, up to the quote or space that ends it.
      PATH = %r{(?:api\.github\.com/)?\b((?:repos|orgs|user|search|enterprises)/[^\s"'\\)]+)}

      attr_reader :line, :text

      # @param lines [Array<String>] the file's lines
      # @param index [Integer] where the call starts
      def initialize(lines, index)
        @line = index + 1
        @lines = lines
        @text = joined(index)
        @index = index
      end

      # @return [String, nil] the path the call reads, with its query
      def path = @text[PATH, 1]

      # @return [String] the path without its query
      def route = path.to_s.split("?").first.to_s

      # @return [String] the query of the path
      def query = path.to_s.split("?", 2)[1].to_s

      # @return [String] the lines after the call, where its answer is compared
      def after = @lines[(@index + 1)..(@index + REACH)].to_a.join

      # @return [String] the lines before the call, where a loop opens
      def before = @lines[[@index - REACH, 0].max...@index].join

      private

      def joined(index)
        text = @lines[index].dup
        text << @lines[index += 1] while text.rstrip.end_with?("\\") && @lines[index + 1]
        text
      end
    end
  end
end
