# frozen_string_literal: true

require "json"
require "psych"

module Hecks
  module Projections
    module CiPipeline
      # The few shapes of YAML text a workflow needs: a scalar quoted only where YAML needs it, a
      # comment, a literal block for a command and a folded block for a long condition.
      #
      # A scalar is written as the row spells it, so `14` and `false` stay a number and a boolean
      # and any other text is the string, in double quotes when plain text would read as something
      # else. Every function answers lines without a trailing newline.
      module YamlText
        # The longest a `key: value` line may be before a condition folds onto its own lines.
        WIDTH = 100

        # A character that makes plain text mean something other than a string when it comes first.
        INDICATOR = /\A[-?:,\[\]{}#&*!|>'"%@`]/

        # Text plain YAML cannot carry as it stands: padding, a colon, a comment, a line break.
        UNPLAIN = /\A\s|\s\z|: | #|\n/

        # Text that would not survive being folded at its spaces: a line break or padding.
        UNFOLDABLE = /\n|\A\s|\s\z|\s\s/

        # The line breaks that end a command.
        TRAILING_BREAKS = /\n+\z/

        # A key YAML takes bare.
        BARE_KEY = /\A[A-Za-z_][\w.-]*\z/

        # What a literal block's header says about the breaks that end it: none, one or all.
        KEEP = { 0 => "-", 1 => "" }.freeze

        module_function

        # @param text [String] a key
        # @return [String] the key, quoted when it is not a plain word
        def key(text) = BARE_KEY.match?(text) ? text : JSON.generate(text)

        # @param value [String, Integer, Boolean] a row's value
        # @return [String] the scalar as YAML text
        def scalar(value)
          return value.to_s unless value.is_a?(String)

          plain?(value) ? value : JSON.generate(value)
        end

        # @param text [String] some text
        # @return [Boolean] whether plain YAML reads it back as a scalar that spells the same text
        def plain?(text)
          return false if text.empty? || text.match?(INDICATOR) || text.match?(UNPLAIN)

          read = Psych.safe_load("v: #{text}").fetch("v")
          !read.is_a?(Hash) && !read.is_a?(Array) && read.to_s == text
        rescue Psych::Exception
          false
        end

        # @param text [String] a note, one line per line of text
        # @return [Array<String>] the comment lines, a blank line as a bare `#`
        def comment(text)
          text.split("\n", -1).map { |line| line.empty? ? "#" : "# #{line}" }
        end

        # @param key [String] the key the value belongs to
        # @param text [String] a condition
        # @return [Array<String>] one line, or the key and a folded block when the line is long
        def folded(key, text)
          line = "#{key}: #{scalar(text)}"
          return [line] if line.length <= WIDTH || text.match?(UNFOLDABLE)

          ["#{key}: >-", *wrap(text).map { |row| "  #{row}" }]
        end

        # @param key [String] the key the value belongs to
        # @param text [String] a command
        # @return [Array<String>] one line for a one-line command, else the key and a literal block
        def literal(key, text)
          return ["#{key}: #{scalar(text)}"] unless text.include?("\n")

          body = text.sub(TRAILING_BREAKS, "")
          breaks = text.length - body.length
          rows = body.split("\n", -1).map { |row| row.empty? ? "" : "  #{row}" }
          ["#{key}: |#{KEEP.fetch(breaks, "+")}", *rows, *[""] * [breaks - 1, 0].max]
        end

        # @param lines [Array<String>] lines
        # @param width [Integer] how many spaces to put before each non-empty one
        # @return [Array<String>] the indented lines
        def indent(lines, width) = lines.map { |line| line.empty? ? line : "#{" " * width}#{line}" }

        # @return [Array<String>] the words of the text packed into lines of at most the width
        def wrap(text)
          text.split.each_with_object([]) do |word, rows|
            rows.empty? || rows.last.length + 1 + word.length > WIDTH - 6 ? rows << word.dup : rows.last << " #{word}"
          end
        end
      end
    end
  end
end
