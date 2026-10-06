module Hecks
  module Fuzzing
    module BoundedExhaustiveExpressions
      # The small, pure expression builders the production rules assemble: one construct over
      # an operand list, with no recursion into `bounded` or `productions`.
      module Fragments
        # Equality and ordering over sampled numeric and string pairs.
        #
        # @param num [Array<String>] numeric operands
        # @param str [Array<String>] string operands
        # @return [Array<String>] the comparison expressions
        def comparisons(num, str)
          pairs(num).map { |a, b| "#{a} == #{b}" } +
            pairs(num).map { |a, b| "#{a} > #{b}" } +
            pairs(str).map { |a, b| "#{a} == #{b}" } +
            pairs(str).map { |a, b| "#{a} < #{b}" }
        end

        # `And`, `Or` and `Not` over a boolean operand list.
        #
        # @param sub [Array<String>] boolean operands
        # @return [Array<String>] the connective expressions
        def connectives(sub)
          pairs(sub).flat_map { |a, b| ["#{a} && #{b}", "#{a} || #{b}"] } + sub.map { |b| "!#{b}" }
        end

        # The string predicates, grouped by predicate rather than by operand.
        #
        # @param str [Array<String>] string operands
        # @return [Array<String>] the predicate expressions
        def string_tests(str)
          str.map { |s| "#{s}.match?(/a/)" } +
            str.flat_map { |s| ["#{s}.present?", "#{s}.blank?"] } +
            str.flat_map { |s| ["#{s}.start_with?(\"a\")", "#{s}.end_with?(\"a\")"] }
        end

        # The string predicates for one operand.
        #
        # @param str [String] a string expression
        # @return [Array<String>] the predicate expressions
        def string_suffix_tests(str)
          ["#{str}.present?", "#{str}.blank?", "#{str}.match?(/a/)", "#{str}.start_with?(\"a\")", "#{str}.end_with?(\"a\")"]
        end

        # @param numerics [Array<String>] numeric expressions
        # @return [Array<String>] `.positive?`, `.negative?` and `.zero?` over each
        def sign_tests(numerics)
          numerics.flat_map { |n| ["#{n}.positive?", "#{n}.negative?", "#{n}.zero?"] }
        end

        # @param operands [Array<String>] string or array expressions
        # @return [Array<String>] `.empty?` over each
        def empty_tests(operands) = operands.map { |x| "#{x}.empty?" }

        # @param arrays [Array<String>] array expressions
        # @return [Array<String>] `.first` and `.last` over each
        def first_and_last(arrays) = arrays.flat_map { |a| ["#{a}.first", "#{a}.last"] }
      end
    end
  end
end
