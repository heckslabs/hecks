require "ripper"

module Hecks
  module DocStaleness
    # The comments of a Ruby file: the lexer's comment tokens, so a `#` in a string is not one.
    module RubyComments
      HASHES = /\A#+/

      module_function

      # @param text [String] Ruby source
      # @return [Array<Array(Integer, String)>] each comment's line and its text without the `#`
      def of(text)
        (Ripper.lex(text) || []).filter_map do |(line, _column), type, token|
          [line, token.sub(HASHES, "")] if type == :on_comment
        end
      end
    end

    # The comments of a Rust file: from a `//` outside a string literal to the end of the line.
    module RustComments
      LITERAL = /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])'/
      SLASHES = %r{\A//[/!]?}

      module_function

      # @param text [String] Rust source
      # @return [Array<Array(Integer, String)>] each comment's line and its text without the slashes
      def of(text)
        text.lines.each_with_index.filter_map do |line, index|
          at = line.gsub(LITERAL) { |literal| "_" * literal.size }.index("//")
          [index + 1, line[at..].sub(SLASHES, "")] if at
        end
      end
    end
  end
end
