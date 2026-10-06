module Hecks
  module Literal
    # Splits the text between a literal's outer braces or brackets on separator commas only:
    # never one inside a quoted string or a nested brace or bracket.
    class ItemSplitter
      # @param body [String] the text between a literal's outer braces or brackets
      def initialize(body)
        @body = body
        @items = []
        @current = +""
        @depth = 0
        @quoting = false
        @escaping = false
      end

      # @return [Array<String>] each item's raw text, stripped, with empty items dropped
      def call
        @body.each_char do |char|
          @current << char
          consume(char)
        end
        @items << @current
        @items.map(&:strip).reject(&:empty?)
      end

      private

      def consume(char)
        return @escaping = false if @escaping
        return @escaping = true if @quoting && char == "\\"
        return @quoting = !@quoting if char == '"'

        track_nesting(char) unless @quoting
      end

      # Follows brace and bracket depth, and separates at a comma outside any.
      def track_nesting(char)
        @depth += 1 if "{[".include?(char)
        @depth -= 1 if "}]".include?(char)
        separate if char == "," && @depth.zero?
      end

      def separate
        @current.chop!
        @items << @current
        @current = +""
      end
    end
  end
end
