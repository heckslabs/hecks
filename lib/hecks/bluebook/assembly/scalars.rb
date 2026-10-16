module Hecks
  module Bluebook
    class Assembly
      # How a `member` cell is spelled as stored text, and read back. The meta-domain holds a cell
      # as text, so a quoted `"true"` and a bare `true` need different spellings: a boolean or
      # number is its own spelling, and a String that would read back as one, or as quoted text,
      # is quoted so it stays a String. The Rust parser reads a cell the same way (`cell_value`
      # in `parse/value_object.rs`).
      module Scalars
        module_function

        # @param value [Object] a cell as the builder holds it
        # @return [Object] `value` itself unless it is a String that reads back as another type, in
        #   which case its quoted spelling
        def mark(value)
          return value unless value.is_a?(String)

          unmark(value) == value ? value : Literal.quote(value)
        end

        # Unlike `Literal.read`, a bare word stays a String, because a closed set admits words far
        # more often than symbols; quoted text is a String whatever it spells.
        #
        # @param value [#to_s] a cell's stored text
        # @return [Object] the String, boolean or number the text spells
        def unmark(value)
          text = value.to_s
          return Literal.unquote(text) if Literal.quoted?(text)
          return true       if text == "true"
          return false      if text == "false"
          return text.to_i  if text.match?(/\A-?\d+\z/)
          return text.to_f  if text.match?(/\A-?\d+\.\d+\z/)

          text
        end
      end
    end
  end
end
