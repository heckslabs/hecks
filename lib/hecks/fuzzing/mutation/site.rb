module Hecks
  module Fuzzing
    module Mutation
      # One place a small semantic change can be made to a bluebook's source: which `operator`
      # (a key of `Operators::CATALOG`), in which `file` (relative to the domain directory), at
      # which `line` (the first it touches, from 1), how many lines it `removed` from there, the
      # `replacement` lines that stand in their place (none for a pure removal) and the `original`
      # line, for a report.
      Site = Struct.new(:operator, :file, :line, :removed, :replacement, :original, keyword_init: true) do
        # @return [String] the stable name of this mutant, `operator@file:line`
        def id = "#{operator}@#{file}:#{line}"

        # @param lines [Array<String>] the bluebook's lines, newline-terminated
        # @return [Array<String>] the lines with this change made
        def apply(lines)
          lines.dup.tap { |changed| changed[line - 1, removed] = replacement }
        end
      end
    end
  end
end
