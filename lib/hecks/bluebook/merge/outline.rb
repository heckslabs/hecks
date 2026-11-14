require "prism"
require_relative "member"
require_relative "label"

module Hecks
  module Bluebook
    module Merge
      # Reads one source text into its tree of members. The text is parsed, never loaded, so a
      # file is outlined without booting its domain.
      #
      # A member owns whole lines. A block whose statements share a line with each other or with
      # the block's own opening or closing is kept as one piece of text, with no members.
      class Outline
        COMMENT = /\A\s*#/

        # @param text [String] the source of a bluebook, hecksagon or world file
        # @return [Member] the file as a member, its declarations as children
        # @raise [Unreadable] if the text is not valid Ruby
        def self.call(text) = new(text).root

        # @param text [String] the source to outline
        def initialize(text)
          parsed = ::Prism.parse(text)
          raise Unreadable, parsed.errors.first.message unless parsed.success?

          @lines = text.lines
          @program = parsed.value
        end

        # @return [Member] the whole file
        def root
          statements = @program.statements
          parts = body(statements.body, 1, @lines.size)
          parts ||= { head: @lines.join, children: nil, tail: "" }
          Member.new(word: "file", name: nil, named: false, lead: "", head: "", foot: "", **parts)
        end

        private

        # The members of the statements written on lines `from` to `upto`, or nil when the
        # statements do not each own their lines.
        def body(statements, from, upto)
          spans = statements.map { |node| [first_line(node.location), last_line(node)] }
          return nil unless separate?(spans, from, upto)

          cursor = from
          children = statements.zip(spans).map do |node, (first, last)|
            start = comment_start(first, cursor)
            member(node, lines(cursor, start - 1), start, last).tap { cursor = last + 1 }
          end
          { children: children, tail: lines(cursor, upto) }
        end

        def separate?(spans, from, upto)
          floors = [from - 1, *spans.map(&:last)]
          spans.each_with_index.all? { |(first, last), index| floors[index] < first && last <= upto }
        end

        def member(node, lead, start, last)
          parts = block_parts(node)
          shape = parts ? { head: lines(start, parts[:open]), foot: lines(parts[:close], last) } : {}
          shape = { head: lines(start, last), foot: "", children: nil, tail: "" } unless parts
          Member.new(lead: lead, **Label.of(node), **shape, **(parts || {}).slice(:children, :tail))
        end

        # The members inside a call's block and the lines that open and close it, or nil when the
        # call has no block laid out over lines of its own.
        def block_parts(node)
          block = laid_out_block(node) or return nil
          open = first_line(block.opening_loc)
          close = first_line(block.closing_loc)
          inside = block.body
          inner = body(inside ? inside.body : [], open + 1, close - 1)
          inner && { open: open, close: close, **inner }
        end

        # A call's block when it opens and closes on different lines and holds plain statements.
        def laid_out_block(node)
          block = node.is_a?(::Prism::CallNode) && node.block
          return nil unless block.is_a?(::Prism::BlockNode)
          return nil if first_line(block.opening_loc) == first_line(block.closing_loc)

          block if [NilClass, ::Prism::StatementsNode].include?(block.body.class)
        end

        # The first of the comment lines directly above a statement, no higher than `floor`.
        def comment_start(first, floor)
          first -= 1 while first > floor && @lines[first - 2].match?(COMMENT)
          first
        end

        # The last line a statement reaches, a heredoc's closing line included.
        def last_line(node)
          closing = node.closing_loc if node.respond_to?(:closing_loc)
          ends = [end_line(node.location), closing && first_line(closing)]
          (ends.compact + node.compact_child_nodes.map { |child| last_line(child) }).max
        end

        def end_line(location) = location.end_line

        def first_line(location) = location.start_line

        def lines(from, upto) = upto < from ? "" : @lines[(from - 1)..(upto - 1)].join
      end
    end
  end
end
