# frozen_string_literal: true

require "json"

module Hecks
  module CLI
    # The command behind `bin/pattern-cases`: records the expected match results for `pattern:`
    # cases, which `spec/pattern_subset_spec.rb` reads from `spec/corpus/fixtures/patterns.json`.
    #
    # The inputs cover embedded and trailing newlines and non-ASCII digits and word characters.
    module PatternCases
      # Each pattern with the inputs it is matched against.
      CASES = [
        ["^[A-Z]{3}-[0-9]{4}$", ["ABC-1234", "abc-1234", "xx\nABC-1234\nyy", "ABC-1234\n", "ABC-١٢٣٤"]],
        ["^[0-9]{5}(-[0-9]{4})?$", ["12345", "12345-6789", "1234", "12345\nx", "١٢٣٤٥"]],
        ['^[^@ ]+@[^@ ]+\.[^@ ]+$', ["a@b.co", "a b@c.co", "no-at-sign", "a@b.co\nevil", "\na@b.co", "café@x.co"]],
        ["^(red|green|blue)$", ["red", "purple", "red\ngreen", "RED", "x\nred"]],
        ["^[A-Za-z0-9_]+$", ["abc_1", "a b", "café", "abc\ndef"]],
        ['^[ \t]*$', ["", "   ", " ", "a", "\n", "\t"]],
        ["^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$", ["12345678-1234-1234-1234-123456789abc", "nope"]],
        ['^\+?[0-9 ()-]{7,20}$', ["+44 20 1234", "abc", "+44 20 1234\nx"]],
        ['\Aonly\z', ["only", "only\n", "x\nonly"]],
        ["^a.c$", ["abc", "a\nc", "a\tc", "aéc"]]
      ].freeze

      module_function

      # @return [Array<Hash{String => Object}>] one row per pattern and input, with its match result
      def rows
        CASES.flat_map do |pattern, inputs|
          regexp = Regexp.new(pattern)
          inputs.map { |input| { "pattern" => pattern, "input" => input, "matches" => regexp.match?(input) } }
        end
      end

      # Prints the rows as pretty JSON.
      #
      # @param out [IO] where the JSON goes
      # @return [Integer] the exit status, always 0
      def call(out: $stdout)
        out.puts JSON.pretty_generate(rows)
        0
      end
    end
  end
end
