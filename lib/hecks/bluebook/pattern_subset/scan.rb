module Hecks
  module Bluebook
    module PatternSubset
      # A left-to-right reading position in a pattern's characters, tracking whether it is inside
      # a `[...]` class: there quantifier characters are literals, and `]` closes the class
      # unless it is the first character after `[` or `[^`.
      class Scan
        attr_reader :chars, :index

        # @param chars [Array<String>] the pattern's characters
        def initialize(chars)
          @chars = chars
          @index = 0
          @in_class = false
          @class_start = nil
        end

        # @return [Boolean] whether every character has been read
        def done? = @index >= @chars.length

        # @return [String, nil] the character at the current position
        def char = @chars[@index]

        # @param offset [Integer] how far past the current position to look
        # @return [String, nil] the character `offset` places ahead
        def peek(offset = 1) = @chars[@index + offset]

        # @return [Boolean] whether the position is inside a `[...]` class
        def in_class? = @in_class

        # @return [Boolean] whether the current `]` closes the open class
        def closing_bracket? = char == "]" && @index != @class_start

        # Reads `count` characters.
        #
        # @param count [Integer] how many characters to consume
        # @return [String] the characters read, as text
        def take(count = 1)
          text = @chars[@index, count].join
          @index += count
          text
        end

        # Opens a class at the current `[`, without consuming it.
        #
        # @return [void]
        def enter_class
          @in_class = true
          @class_start = @index + 1
          @class_start += 1 if @chars[@class_start] == "^"
        end

        # @return [void]
        def leave_class = @in_class = false
      end
    end
  end
end
