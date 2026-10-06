# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module RustCommentStyle
      # Finds Rust source's line comments, distinguishing them from `//` inside
      # code, strings, raw strings, and char literals. Block comments are not recognised.
      class Tokenizer
        # Lexes `source` for its line comments in one pass.
        def self.comments(source)
          new(source).run
        end

        def initialize(source)
          @src = source
          @len = source.length
          @comments = []
        end

        # Walks the whole source once, collecting every line comment.
        def run
          pos = 0
          line = 1
          col = 0
          pos, col, line = step(pos, col, line) while pos < @len
          @comments
        end

        private

        # Consumes the token at `pos`.
        #
        # @return [Array(Integer, Integer, Integer)] the next position, column and line
        def step(pos, col, line)
          case @src[pos]
          when "\n" then [pos + 1, 0, line + 1]
          when "/" then [*consume_slash(pos, col, line), line]
          when '"' then consume_string(pos, col, line)
          when "'" then [*consume_quote(pos, col), line]
          when "r" then consume_maybe_raw_string(pos, col, line)
          else [pos + 1, col + 1, line]
          end
        end

        def consume_slash(pos, col, line)
          return advance_plain(pos, col) unless @src[pos, 2] == "//"

          finish = @src.index("\n", pos) || @len
          text = @src[pos...finish]
          @comments << Comment.new(line, col, text, full_line_before?(pos))
          [finish, col + text.length]
        end

        # Whether only whitespace precedes `pos` on its line.
        def full_line_before?(pos)
          last_newline = @src.rindex("\n", pos.zero? ? 0 : pos - 1)
          prefix = last_newline && last_newline < pos ? @src[(last_newline + 1)...pos] : @src[0...pos]
          prefix.strip.empty?
        end

        def consume_string(pos, col, line)
          idx = pos + 1
          idx += (@src[idx] == "\\" ? 2 : 1) while idx < @len && @src[idx] != '"'
          advance_span(pos, idx + 1, col, line)
        end

        def consume_quote(pos, col)
          match = @src[pos..].match(/\A'(?:\\.|[^'\\\n]){1}'/)
          match ? [pos + match[0].length, col + match[0].length] : [pos + 1, col + 1]
        end

        def consume_maybe_raw_string(pos, col, line)
          idx = pos + 1
          hashes = 0
          hashes += 1 while @src[idx + hashes] == "#"
          return [pos + 1, col + 1, line] unless @src[idx + hashes] == '"'

          close = @src.index("\"#{"#" * hashes}", idx + hashes + 1) || @len
          advance_span(pos, close + 1 + hashes, col, line)
        end

        def advance_span(from, to, col, line)
          segment = @src[from...to]
          newlines = segment.count("\n")
          if newlines.positive?
            col = segment.length - segment.rindex("\n") - 1
            line += newlines
          else
            col += segment.length
          end
          [to, col, line]
        end

        def advance_plain(pos, col)
          [pos + 1, col + 1]
        end
      end
    end
  end
end
