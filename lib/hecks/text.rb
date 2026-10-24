module Hecks
  # Plain-text readings the framework takes again and again: the first line of a message, a
  # comma-separated list, whether a value says anything at all. Each pipeline is named here once,
  # so a caller says what it wants instead of replaying how to get it.
  module Text
    # Any run of whitespace.
    WHITESPACE = /\s+/

    # A comma and the space around it, as in "a, b ,c".
    COMMA = /\s*,\s*/

    module_function

    # The first line of `text`, stripped. Error messages put their sentence on the first line.
    #
    # @param text [String, #to_s, nil] the text to read
    # @return [String] the first line without surrounding whitespace, or `""` for no text
    def first_line(text)
      line = text.to_s.lines.first
      line.to_s.strip
    end

    # The last `count` lines of `text`, joined and stripped: the tail of a command's output.
    #
    # @param text [String, #to_s, nil] the text to read
    # @param count [Integer] how many lines to keep
    # @return [String] the kept lines, joined, without surrounding whitespace
    def last_lines(text, count)
      tail = text.to_s.lines.last(count)
      tail.join.strip
    end

    # Says whether `value` holds no text once whitespace is set aside.
    #
    # @param value [String, #to_s, nil] the value to read
    # @return [Boolean] whether `value` is `nil`, empty or only whitespace
    def blank?(value) = value.to_s.strip.empty?

    # Splits a comma-separated value into its items, dropping empty ones.
    #
    # @param value [String, #to_s, nil] a list such as `"a, b,,c"`
    # @return [Array<String>] the stripped, non-empty items, in order
    def comma_list(value)
      items = value.to_s.split(",")
      items.map(&:strip).reject(&:empty?)
    end

    # Joins the stripped, non-empty lines of `lines` back into one text.
    #
    # @param lines [Array<String>] the lines to keep
    # @return [String] the non-blank lines, stripped, one per line
    def compact_lines(lines)
      kept = lines.map(&:strip).reject(&:empty?)
      kept.join("\n")
    end

    # The names of `items`, sorted and comma-joined: how a refusal lists what it would accept.
    #
    # @param items [Array<#name>] the things to name
    # @return [String] their names, sorted, joined with ", "
    def name_list(items) = items.map(&:name).sort.join(", ")
  end
end
