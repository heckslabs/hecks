# Parsing of the `Resolver` leaf grammar: one step per leaf form, tried in precedence order.
module Hecks
  module Bluebook
    module Expression
      # Reopens `Resolver` (see resolver.rb) for `parse` and its steps.
      module Resolver
        module_function

        # The suffix calls that wrap one receiver, each matched as `<receiver>.<suffix>`.
        # A suffix naming a node class builds it over the receiver alone; a flag suffix also sets
        # `negated`.
        RECEIVER_SUFFIXES = [
          [/\A(.+)\.empty\?\z/, Empty, {}], [/\A(.+)\.to_s\z/, ToS, {}], [/\A(.+)\.size\z/, Size, {}],
          [/\A(.+)\.first\z/, First, {}], [/\A(.+)\.last\z/, Last, {}],
          [/\A(.+)\.present\?\z/, Presence, { negated: false }], [/\A(.+)\.blank\?\z/, Presence, { negated: true }],
          [/\A(.+)\.set\?\z/, Assignment, { negated: false }], [/\A(.+)\.unset\?\z/, Assignment, { negated: true }]
        ].freeze

        # The strip family, each matched as `<receiver>.<call>`, naming which ends it trims.
        STRIP_SUFFIXES = [
          [/\A(.+)\.strip\z/, :both], [/\A(.+)\.lstrip\z/, :left], [/\A(.+)\.rstrip\z/, :right]
        ].freeze

        # The suffix calls that carry one quoted argument, as `<receiver>.<call>("<argument>")`.
        TEXT_SUFFIXES = [
          [/\A(.+)\.split\("([^"]*)"\)\z/, Split, :separator],
          [/\A(.+)\.start_with\?\("([^"]*)"\)\z/, StartsWith, :substring],
          [/\A(.+)\.end_with\?\("([^"]*)"\)\z/, EndsWith, :substring]
        ].freeze

        # Every step `parse` tries, in precedence order (`.length` first, sign tests before the
        # rest); each answers a node, or `nil` when the expression is not its form.
        PARSE_STEPS = [:parse_length, :parse_literal, :parse_array, :parse_addition, :parse_sign_test,
                       :parse_receiver_suffix, :parse_strip, :parse_modulo, :parse_matches_regex, :parse_text_suffix,
                       :parse_block_opener].freeze

        # @param expr [String] the leaf expression text
        # @return [Object] the parsed leaf node, or `Lookup` when nothing else matches
        def parse(expr)
          expr = expr.to_s.strip

          PARSE_STEPS.each do |step|
            node = public_send(step, expr)
            return node if node
          end
          Lookup.new(path: expr)
        end

        def parse_length(expr)
          length = expr.match(/\A(.+)\.length\z/)
          Size.new(receiver: parse(length[1])) if length
        end

        def parse_literal(expr)
          return StringLiteral.new(value: expr[1..-2]) if quoted?(expr)

          case expr
          when /\A-?\d+\z/       then IntegerLiteral.new(value: Integer(expr, 10))
          when /\A-?\d*\.\d+\z/  then FloatLiteral.new(value: Float(expr))
          when "true", "false"   then BoolLiteral.new(value: expr == "true")
          when "nil"             then NilLiteral.new
          end
        end

        def parse_array(expr)
          elements = array_elements(expr)
          ArrayLiteral.new(elements: elements.map { |element| parse(element) }) if elements
        end

        def parse_addition(expr)
          arithmetic = split_addition(expr)
          Addition.new(left: parse(arithmetic[0]), right: parse(arithmetic[1])) if arithmetic
        end

        def parse_sign_test(expr)
          sign = match_suffix(expr, SIGN_TESTS)
          sign_test_node(sign) if sign
        end

        def parse_receiver_suffix(expr)
          RECEIVER_SUFFIXES.each do |pattern, node_class, extra|
            match = expr.match(pattern)
            return node_class.new(receiver: parse(match[1]), **extra) if match
          end
          nil
        end

        def parse_strip(expr)
          STRIP_SUFFIXES.each do |pattern, side|
            match = expr.match(pattern)
            return Strip.new(receiver: parse(match[1]), side: side) if match
          end
          nil
        end

        def parse_modulo(expr)
          modulo = match_call(expr, ".modulo(")
          Modulo.new(receiver: parse(modulo[0]), divisor: parse(modulo[1])) if modulo
        end

        def parse_matches_regex(expr)
          match = expr.match(%r{\A(.+)\.match\?\(/(.*)/([a-z]*)\)\z}m)
          MatchesRegex.new(receiver: parse(match[1]), pattern: match[2], flags: match[3]) if match
        end

        def parse_text_suffix(expr)
          TEXT_SUFFIXES.each do |pattern, node_class, field|
            match = expr.match(pattern)
            return node_class.new(receiver: parse(match[1]), field => match[2]) if match
          end
          nil
        end

        def sign_test_node(parts)
          receiver, test = parts
          symbol   = SIGN_TEST_OPERATORS.fetch(test)
          operator = Evaluator::OPERATORS.find { |candidate| candidate.symbol == symbol }
          SignTest.new(operator: operator, test: test, receiver: parse(receiver))
        end
      end
    end
  end
end
