# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module CommentStyle
      # Blanks the spans of a comment that must keep their capitals (code spans, quotes, SQL), and
      # decides which capitalised SQL keywords on a line to leave alone.
      module Masking
        private

        # The comment with every span that must keep its capitals blanked out. A
        # backtick span can wrap across lines, so whether this line opens inside
        # one comes from the lines above it.
        def mask(comment)
          head, text = open_span_head(comment)
          body = text.gsub(PROTECTED_SPANS) { |span| quoted_heading?(span) ? span : FILLER * span.length }
          head + blank_unclosed(body)
        end

        # Blanks the start of a line that continues a backtick span opened above it.
        #
        # @return [Array(String, String)] the blanked head, and the rest of the text
        def open_span_head(comment)
          text = comment.text
          return ["", text] unless @open_spans[comment.line]

          lead = text[/\A#+\s*/].length
          close = text.index("`", lead)
          cut = close ? close + 1 : text.length
          [text[0, lead] + (FILLER * (cut - lead)), text[cut..]]
        end

        # Blanks a backtick span left open at the end of the line.
        def blank_unclosed(body)
          open = body.rindex("`")
          open ? body[0, open] + (FILLER * (body.length - open)) : body
        end

        # Which lines begin inside a backtick span opened earlier in the paragraph.
        def open_spans
          inside = false
          @comments.each_with_object({}) do |comment, open|
            inside = false unless continues_paragraph?(comment)
            open[comment.line] = inside
            inside ^= comment.text.count("`").odd?
          end
        end

        def continues_paragraph?(comment)
          above = @by_line[comment.line - 1]
          comment.full_line && above&.full_line && !above.text.match?(/\A#+\s*\z/)
        end

        # Capitalised SQL keywords to leave alone on this line. A keyword such as
        # `FROM` or `SET` is only SQL when the rest of the line reads as SQL too.
        def sql_keywords(comment, words)
          bare, strong, weak = sql_classes(words)
          return bare.to_set if reads_as_sql?(bare, strong, weak)
          return (strong + weak).to_set if comment.text.match?(SQL_PHRASES)

          database_file? ? strong.to_set : Set.new
        end

        def sql_classes(words)
          bare = words.map { |word| word.sub(/'[A-Z]{1,2}\z/, "") } - ["A"]
          [bare, bare.select { |word| SQL_STRONG.include?(word) }, bare.select { |word| SQL_WEAK.include?(word) }]
        end

        def database_file?
          path.match?(SQL_PATH)
        end

        def reads_as_sql?(bare, strong, weak)
          only_sql = bare.all? do |word|
            [SQL_STRONG, SQL_WEAK, SQL_NEUTRAL, ACRONYMS].any? { |set| set.include?(word) }
          end
          return false unless only_sql

          database_file? ? (strong.any? || weak.any?) : (strong.any? && (strong + weak).size >= 2)
        end

        # A quoted run of capitals is another comment's heading, not a literal.
        def quoted_heading?(span)
          return false unless span.start_with?('"') && !span.match?(SQL_PHRASES)

          capitals = span.scan(/\b[A-Z]{2,}\b/).size
          capitals >= 3 || (capitals == 2 && !span.match?(/[a-z]/))
        end
      end
    end
  end
end
