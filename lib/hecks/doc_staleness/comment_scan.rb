require_relative "finding"
require_relative "path_citation"
require_relative "constant_index"
require_relative "ruby_comments"
require_relative "yard_params"
require_relative "sources"

module Hecks
  module DocStaleness
    # The comments of a Ruby or Rust file: the repo paths and `Hecks::` constants they cite, and for
    # Ruby the `@param` tags that name no parameter. Strings are not read.
    class CommentScan
      # @param root [String] the checkout
      # @param path [String] the file, relative to `root`
      # @param text [String] its text
      # @param index [ConstantIndex] what lib/ defines
      def initialize(root, path, text, index)
        @root = root
        @path = path
        @text = text
        @index = index
        @lines = text.lines
        @ruby = path.end_with?(".rb")
      end

      # @return [Array<Finding>] the stale citations, by line
      def findings
        comments = @ruby ? RubyComments.of(@text) : RustComments.of(@text)
        (cited(comments) + params(comments)).sort_by(&:line)
      end

      private

      def cited(comments)
        unmarked(comments).flat_map do |(line, text)|
          PathCitation.missing(text, @root).map { |path| found(line, "comment-path", "`#{path}` does not exist") } +
            @index.missing(text).map { |name| found(line, "comment-constant", "#{name} is not defined in lib/") }
        end
      end

      def params(comments)
        return [] unless @ruby

        unmarked(YardParams.new(@text, comments).stale).map do |(line, name)|
          found(line, "yard-param", "@param #{name} is not a parameter of the method below")
        end
      end

      def unmarked(entries) = entries.reject { |(line, _)| Sources.marked?(@lines, line - 1) }

      def found(line, kind, reason) = Finding.new(@path, line, kind, reason)
    end
  end
end
