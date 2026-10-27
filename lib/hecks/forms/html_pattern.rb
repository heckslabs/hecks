require "strscan"

module Hecks
  module Forms
    # An attribute's pattern as an input's `pattern` attribute carries it.
    #
    # The domain reads a pattern as Ruby and finds it anywhere in a value; a browser reads the
    # `pattern` attribute as JavaScript, in its `v` mode, and holds it to the whole value. So the
    # pattern is wrapped to be found anywhere, which keeps `^https?://` from accepting only the
    # scheme and `[^ \t\n\r]` from accepting one character, and what Ruby spells differently is
    # rewritten: `\A` and `\z` as `^` and `$`, `\h` as a hex range, and inside a character class a
    # literal `-`, `(`, `)`, `{`, `}`, `|` and `/` escaped, which `v` mode refuses bare. A browser
    # ignores a pattern it cannot compile, so a pattern left as Ruby wrote it is not checked at all.
    class HtmlPattern
      # What Ruby writes outside a character class, and the JavaScript for it.
      OUTSIDE = { "A" => "^", "z" => "$", "Z" => "$", "h" => "[0-9a-fA-F]" }.freeze

      # The same inside a character class, where only the hex digit means something.
      INSIDE = { "h" => "0-9a-fA-F" }.freeze

      # Characters `v` mode refuses unescaped inside a character class.
      RESERVED = %w[( ) { } | /].freeze

      # A backslash and the character it escapes.
      ESCAPE = /\\(.)/m

      # The end of a character class.
      CLASS_END = /\]/

      # @param pattern [String, nil] the attribute's pattern
      # @return [String, nil] the pattern for an input, or nil when the attribute has none
      def self.for(pattern) = pattern && new(pattern).to_s

      # @param pattern [String] the attribute's pattern
      def initialize(pattern)
        @pattern = pattern
        @depth = 0
      end

      # @return [String] the pattern, wrapped to be found anywhere in the value
      def to_s = ".*(?:#{translated}).*"

      private

      def translated
        scanner = StringScanner.new(@pattern)
        out = +""
        out << step(scanner) until scanner.eos?
        out
      end

      def step(scanner)
        return escaped(scanner[1]) if scanner.scan(ESCAPE)
        return open_class(scanner) if scanner.scan("[")

        @depth.positive? ? in_class(scanner.getch, scanner) : scanner.getch
      end

      def escaped(char)
        (@depth.zero? ? OUTSIDE : INSIDE).fetch(char) { "\\#{char}" }
      end

      # A class opens with its negation and a leading `-` read as the literals they are.
      def open_class(scanner)
        @depth += 1
        opened = +"["
        opened << "^" if scanner.scan("^")
        opened << "\\-" if scanner.scan("-")
        opened
      end

      def in_class(char, scanner)
        @depth -= 1 if char == "]"
        return "\\-" if char == "-" && scanner.check(CLASS_END)

        RESERVED.include?(char) ? "\\#{char}" : char
      end
    end
  end
end
