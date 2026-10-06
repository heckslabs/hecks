# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module RustCommentStyle
      # Blanks the spans of a Rust comment that must keep their capitals (code spans, quotes, SQL),
      # and decides which capitalised SQL keywords on a line to leave alone.
      module Masking
        private

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
          comment.full_line && above&.full_line && !above.text.match?(%r{\A/{2,3}!?\s*\z})
        end

        def mask(comment)
          head, text = open_span_head(comment)
          body = text.gsub(CommentStyle::PROTECTED_SPANS) { |span| quoted_heading?(span) ? span : FILLER * span.length }
          head + blank_unclosed(body)
        end

        # Blanks the start of a line that continues a backtick span opened above it.
        #
        # @return [Array(String, String)] the blanked head, and the rest of the text
        def open_span_head(comment)
          text = comment.text
          return ["", text] unless @open_spans[comment.line]

          lead = text[MARKER].to_s.length
          close = text.index("`", lead)
          cut = close ? close + 1 : text.length
          [text[0, lead] + (FILLER * (cut - lead)), text[cut..]]
        end

        # Blanks a backtick span left open at the end of the line.
        def blank_unclosed(body)
          open = body.rindex("`")
          open ? body[0, open] + (FILLER * (body.length - open)) : body
        end

        def quoted_heading?(span)
          return false unless span.start_with?('"') && !span.match?(CommentStyle::SQL_PHRASES)

          capitals = span.scan(/\b[A-Z]{2,}\b/).size
          capitals >= 3 || (capitals == 2 && !span.match?(/[a-z]/))
        end

        def sql_keywords(comment, words)
          bare, strong, weak = sql_classes(words)
          return bare.to_set if reads_as_sql?(bare, strong, weak)
          return (strong + weak).to_set if comment.text.match?(CommentStyle::SQL_PHRASES)

          database_file? ? strong.to_set : Set.new
        end

        def sql_classes(words)
          bare = words.map { |w| w.sub(/'[A-Z]{1,2}\z/, "") } - ["A"]
          [bare, bare.select { |w| CommentStyle::SQL_STRONG.include?(w) }, bare.select { |w| CommentStyle::SQL_WEAK.include?(w) }]
        end

        def database_file?
          path.match?(CommentStyle::SQL_PATH)
        end

        def reads_as_sql?(bare, strong, weak)
          sql_sets = [CommentStyle::SQL_STRONG, CommentStyle::SQL_WEAK, CommentStyle::SQL_NEUTRAL, CommentStyle::ACRONYMS]
          return false unless bare.all? { |w| sql_sets.any? { |set| set.include?(w) } }

          database_file? ? (strong.any? || weak.any?) : (strong.any? && (strong + weak).size >= 2)
        end
      end
    end
  end
end
