module Hecks
  module Fuzzing
    module Mutation
      # One place a small semantic change can be made to a bluebook's source: which operator, where,
      # and the lines it leaves behind.
      #
      # @!attribute [r] operator
      #   @return [Symbol] the operator's name, a key of `Operators::CATALOG`
      # @!attribute [r] file
      #   @return [String] the bluebook, relative to the domain directory
      # @!attribute [r] line
      #   @return [Integer] the first line the change touches, counting from 1
      # @!attribute [r] removed
      #   @return [Integer] how many lines the change takes out, starting at `line`
      # @!attribute [r] replacement
      #   @return [Array<String>] the lines that stand where they were (empty for a pure removal)
      # @!attribute [r] original
      #   @return [String] the line as it was, for a report
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
