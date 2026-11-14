# frozen_string_literal: true

module Hecks
  module Adapters
    class GitRehearsal
      class SpecMap
        # The named declarations of a bluebook or hecksagon that enclose a line, read by indent.
        class Declarations
          DECLARATION = /^(\s*)(?:aggregate|value_object|entity|command|policy|event|query|workflow|projection)\s+"([^"]+)"/

          LEADING_SPACE = /\A\s*/

          # @param lines [Array<String>] the file's lines
          def initialize(lines)
            @lines = lines
          end

          # @param line [Integer] a 1-based line number
          # @return [Array<String>] the declaration on the line, then each one enclosing it
          def around(line)
            indent = indent_of(@lines[line - 1])
            names = []
            (line - 1).downto(1) do |number|
              found = DECLARATION.match(@lines[number - 1].to_s)
              next unless found && (found[1].size < indent || number == line)

              names << found[2]
              indent = found[1].size
            end
            names
          end

          private

          def indent_of(text) = text.to_s[LEADING_SPACE].size.then { |size| text.to_s.strip.empty? ? 0 : size }
        end
      end
    end
  end
end
