# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module DeployRecipeLint
      # Reads a Makefile into its targets, recipe lines and shell chains.
      module Makefile
        # A target line: a name, a colon, and nothing but prerequisites after it.
        TARGET_LINE = %r{\A([A-Za-z0-9_./$(){}-]+):(?:\s.*)?\z}

        # Maps each target name to its `[line_no, raw_text]` recipe lines, tabs and continuations
        # intact.
        def parse_targets(text)
          lines = text.lines
          targets = {}
          index = 0
          index = read_line(lines, index, targets) while index < lines.length
          targets
        end

        # Drops comment and blank lines; a comment can quote "sam deploy" or "echo" but never runs.
        def real_statements(recipe_lines)
          recipe_lines.reject { |_, text| text.sub(/\A\t/, "").start_with?("#") || text.strip.empty? }
        end

        # Splits real statements into shell chains; Make runs each backslash-terminated run as one
        # shell.
        def shell_chains(recipe_lines)
          statements = real_statements(recipe_lines).map { |line_no, text| continued_statement(line_no, text) }
          statements.slice_after { |_, _, continues| !continues }
                    .map { |chain| chain.map { |line_no, statement, _| [line_no, statement] } }
        end

        # Drops the leading Make `@` and trailing `;` so exit-code checks match the bare statement.
        def normalize_statement(text)
          text.sub(/\A@/, "").strip.sub(/;\s*\z/, "")
        end

        private

        # Reads the target that starts at `index` into `targets`, when a target starts there.
        #
        # @return [Integer] the index of the next line to read
        def read_line(lines, index, targets)
          match = skippable_line?(lines[index]) ? nil : lines[index].match(TARGET_LINE)
          return index + 1 unless match

          targets[match[1]], index = recipe_from(lines, index + 1)
          index
        end

        # A line that neither starts a target nor belongs to a recipe.
        def skippable_line?(line)
          line.start_with?("\t", "#") || line.strip.empty? || line.include?(":=") || line.start_with?(".PHONY")
        end

        # @return [Array(Array, Integer)] the recipe lines from `start` on, and the index after them
        def recipe_from(lines, start)
          recipe = []
          index = start
          while index < lines.length && recipe_line?(lines[index])
            recipe << [index, lines[index].chomp]
            index += 1
          end
          [recipe, index]
        end

        def recipe_line?(line)
          line == "\n" || line.start_with?("\t") || line.start_with?("#")
        end

        # @return [Array] the line number, the statement without its continuation backslash, and
        #   whether it continues on the next line
        def continued_statement(line_no, text)
          stripped = text.sub(/\A\t/, "")
          continues = stripped.end_with?("\\")
          [line_no, continues ? stripped.sub(/\\\z/, "").rstrip : stripped, continues]
        end
      end
    end
  end
end
