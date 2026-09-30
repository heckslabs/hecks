require "json"
require_relative "../../rendering"
require_relative "../../vocabulary"
require_relative "resolver/block_predicates"

module Hecks
  module Bluebook
    module Expression
      class EvaluationError < StandardError; end

      # The dotted/arithmetic leaf grammar a predicate's `Resolve` node bottoms out in.
      # `parse` is a pure function of its string; `interpret` reads state/attrs fresh.
      module Resolver
        SIGN_TESTS = Hecks::Vocabulary.fetch("SignTest")

        # Comparison operator each sign test stands for, against the literal 0.
        SIGN_TEST_OPERATORS = Hecks::Vocabulary.rows("SignTest")
                                               .to_h { |row| [row["name"], row["compares_via"]] }
                                               .freeze

        # Leaf nodes of the grammar. Only Lookup touches state/attrs.
        IntegerLiteral = Struct.new(:value, keyword_init: true)
        FloatLiteral   = Struct.new(:value, keyword_init: true)
        StringLiteral  = Struct.new(:value, keyword_init: true)
        BoolLiteral    = Struct.new(:value, keyword_init: true)
        ArrayLiteral   = Struct.new(:elements, keyword_init: true)
        # A plain class: `Struct.new(keyword_init: true)` with no members raises on Ruby 3.2.
        NilLiteral     = Class.new
        Addition       = Struct.new(:left, :right, keyword_init: true)
        SignTest       = Struct.new(:operator, :test, :receiver, keyword_init: true)
        Empty          = Struct.new(:receiver, keyword_init: true)
        ToS            = Struct.new(:receiver, keyword_init: true)
        Modulo         = Struct.new(:receiver, :divisor, keyword_init: true)
        Size           = Struct.new(:receiver, keyword_init: true)
        Lookup         = Struct.new(:path, keyword_init: true)

        MatchesRegex   = Struct.new(:receiver, :pattern, :flags, keyword_init: true)

        Presence       = Struct.new(:receiver, :negated, keyword_init: true)

        # `.set?`/`.unset?` ask only `!nil?`; unlike `.blank?`, an assigned empty value is set.
        Assignment     = Struct.new(:receiver, :negated, keyword_init: true)

        Split          = Struct.new(:receiver, :separator, keyword_init: true)

        Last           = Struct.new(:receiver, keyword_init: true)

        First          = Struct.new(:receiver, keyword_init: true)

        StartsWith = Struct.new(:receiver, :substring, keyword_init: true)
        EndsWith   = Struct.new(:receiver, :substring, keyword_init: true)

        module_function

        # Parses and interprets `expr` in one step, bypassing `Evaluator`'s boolean grammar.
        #
        # @param expr [String] the dotted/arithmetic leaf expression
        # @param state [Hash{Symbol => Object}] stored attribute values
        # @param attrs [Hash{Symbol => Object}] call arguments, checked before `state`
        # @return [Object] the resolved Integer, Float, String, boolean, nil, or Array
        # @raise [EvaluationError] on an unknown name or a wrongly typed operand
        def resolve(expr, state, attrs)
          interpret(parse(expr), state, attrs)
        end

        # Branch order is the precedence order (`.length` first, sign tests before the rest).
        #
        # @param expr [String] the leaf expression text
        # @return [Object] the parsed leaf node, or `Lookup` when nothing else matches
        # rubocop:disable-next Metrics/AbcSize
        # rubocop:disable-next Metrics/CyclomaticComplexity
        # rubocop:disable-next Metrics/MethodLength
        # rubocop:disable-next Metrics/PerceivedComplexity
        def parse(expr)
          expr = expr.to_s.strip

          return Size.new(receiver: parse(Regexp.last_match(1))) if expr =~ /\A(.+)\.length\z/

          return IntegerLiteral.new(value: Integer(expr, 10)) if expr.match?(/\A-?\d+\z/)
          return FloatLiteral.new(value: Float(expr))         if expr.match?(/\A-?\d*\.\d+\z/)
          return StringLiteral.new(value: expr[1..-2])        if quoted?(expr)
          return BoolLiteral.new(value: true)                 if expr == "true"
          return BoolLiteral.new(value: false)                if expr == "false"
          return NilLiteral.new if expr == "nil"

          elements = array_elements(expr)
          return ArrayLiteral.new(elements: elements.map { |element| parse(element) }) if elements

          arithmetic = split_addition(expr)
          return Addition.new(left: parse(arithmetic[0]), right: parse(arithmetic[1])) if arithmetic

          sign = match_suffix(expr, SIGN_TESTS)
          return sign_test_node(sign) if sign

          return Empty.new(receiver: parse(Regexp.last_match(1))) if expr =~ /\A(.+)\.empty\?\z/
          return ToS.new(receiver: parse(Regexp.last_match(1)))   if expr =~ /\A(.+)\.to_s\z/

          modulo = match_call(expr, ".modulo(")
          return Modulo.new(receiver: parse(modulo[0]), divisor: parse(modulo[1])) if modulo

          return Size.new(receiver: parse(Regexp.last_match(1))) if expr =~ /\A(.+)\.size\z/

          if expr =~ %r{\A(.+)\.match\?\(/(.*)/([a-z]*)\)\z}m
            return MatchesRegex.new(receiver: parse(Regexp.last_match(1)),
                                    pattern:  Regexp.last_match(2),
                                    flags:    Regexp.last_match(3))
          end

          return Presence.new(receiver: parse(Regexp.last_match(1)), negated: false) if expr =~ /\A(.+)\.present\?\z/
          return Presence.new(receiver: parse(Regexp.last_match(1)), negated: true)  if expr =~ /\A(.+)\.blank\?\z/

          return Assignment.new(receiver: parse(Regexp.last_match(1)), negated: false) if expr =~ /\A(.+)\.set\?\z/
          return Assignment.new(receiver: parse(Regexp.last_match(1)), negated: true)  if expr =~ /\A(.+)\.unset\?\z/

          if expr =~ /\A(.+)\.split\("([^"]*)"\)\z/
            return Split.new(receiver:  parse(Regexp.last_match(1)),
                             separator: Regexp.last_match(2))
          end

          return First.new(receiver: parse(Regexp.last_match(1))) if expr =~ /\A(.+)\.first\z/
          return Last.new(receiver: parse(Regexp.last_match(1))) if expr =~ /\A(.+)\.last\z/

          if expr =~ /\A(.+)\.start_with\?\("([^"]*)"\)\z/
            return StartsWith.new(receiver:  parse(Regexp.last_match(1)),
                                  substring: Regexp.last_match(2))
          end

          if expr =~ /\A(.+)\.end_with\?\("([^"]*)"\)\z/
            return EndsWith.new(receiver:  parse(Regexp.last_match(1)),
                                substring: Regexp.last_match(2))
          end

          block_opener = parse_block_opener(expr)
          return block_opener if block_opener

          Lookup.new(path: expr)
        end

        def sign_test_node(parts)
          receiver, test = parts
          symbol   = SIGN_TEST_OPERATORS.fetch(test)
          operator = Evaluator::OPERATORS.find { |candidate| candidate.symbol == symbol }
          SignTest.new(operator: operator, test: test, receiver: parse(receiver))
        end

        # Evaluates a node `parse` produced against `state` and `attrs`.
        #
        # @return [Object] the value the node resolves to
        # @raise [EvaluationError] if the node type is unhandled or an operand is refused
        # rubocop:disable-next Metrics/AbcSize
        # rubocop:disable-next Metrics/CyclomaticComplexity
        # rubocop:disable-next Metrics/MethodLength
        def interpret(node, state, attrs)
          case node
          when IntegerLiteral, FloatLiteral, StringLiteral, BoolLiteral then node.value
          when ArrayLiteral then node.elements.map { |element| interpret(element, state, attrs) }
          when NilLiteral then nil
          when Addition
            add(interpret(node.left, state, attrs), interpret(node.right, state, attrs))
          when SignTest
            apply_sign_test(node, interpret(node.receiver, state, attrs))
          when Empty
            emptiness_of(interpret(node.receiver, state, attrs))
          when ToS
            string_of(interpret(node.receiver, state, attrs))
          when Modulo
            apply_modulo(interpret(node.receiver, state, attrs), interpret(node.divisor, state, attrs))
          when Size
            size_of(interpret(node.receiver, state, attrs))
          when MatchesRegex
            matches_regex?(interpret(node.receiver, state, attrs), node.pattern, node.flags)
          when Presence
            present = !blank?(interpret(node.receiver, state, attrs))
            node.negated ? !present : present
          when Assignment
            set = !interpret(node.receiver, state, attrs).nil?
            node.negated ? !set : set
          when Split
            split_value(interpret(node.receiver, state, attrs), node.separator)
          when Last
            last_of(interpret(node.receiver, state, attrs))
          when First
            first_of(interpret(node.receiver, state, attrs))
          when Find
            found_of(node, interpret(node.receiver, state, attrs), state, attrs)
          when StartsWith
            starts_with?(interpret(node.receiver, state, attrs), node.substring)
          when EndsWith
            ends_with?(interpret(node.receiver, state, attrs), node.substring)
          when BlockPredicate
            evaluate_block_predicate(node, interpret(node.receiver, state, attrs), state, attrs)
          when Lookup
            lookup(node.path, state, attrs)
          else
            # A missing arm must raise; silently returning nil is the one wrong answer
            # this grammar never allows.
            raise EvaluationError, "no interpreter handles #{node.class} — add a case before parse can produce it"
          end
        end

        def blank?(value)
          return true if value.nil? || value == false

          # Duck-typed: reaching across to Runtime::Value would couple the namespaces. A list
          # is judged by its own emptiness, never coerced: `[0].to_h` would raise TypeError.
          value = value.to_h if value.respond_to?(:to_h) && !value.is_a?(Hash) && !value.is_a?(Array)
          case value
          when String, Array, Hash then value.empty?
          else false
          end
        end

        def matches_regex?(receiver_value, pattern, flags)
          text = case receiver_value
                 when String, Symbol, Integer, Float then receiver_value.to_s
                 when NilClass then ""
                 else
                   raise EvaluationError, "match? expects a scalar, got #{receiver_value.class}"
                 end

          options = 0
          options |= Regexp::IGNORECASE if flags.include?("i")
          options |= Regexp::MULTILINE  if flags.include?("m")
          options |= Regexp::EXTENDED   if flags.include?("x")

          Regexp.new(pattern, options).match?(text)
        rescue RegexpError => e
          # A malformed pattern is an author mistake; refuse it as EvaluationError.
          raise EvaluationError, "match? given an invalid pattern #{pattern.inspect} — #{e.message}"
        end

        def array_elements(expr)
          return nil unless expr.start_with?("[") && expr.end_with?("]")

          inner = expr[1..-2].strip
          return [] if inner.empty?

          elements = []
          depth = 0
          quote = nil
          current = +""
          inner.each_char do |char|
            if quote
              quote = nil if char == quote
              current << char
              next
            end
            case char
            when '"', "'" then quote = char
            when "[", "(" then depth += 1
            when "]", ")" then depth -= 1
            end
            if char == "," && depth.zero?
              elements << current.strip
              current = +""
            else
              current << char
            end
          end
          elements << current.strip
          elements.reject(&:empty?)
        end

        # Braces and brackets count toward depth like parens, so a `+` inside a block body
        # or an array element is not this expression's own addition.
        def split_addition(expr)
          depth = 0
          quote = nil

          expr.each_char.with_index do |char, index|
            if quote
              quote = nil if char == quote
            elsif ['"', "'"].include?(char)
              quote = char
            # `[`/`]` count too: an array element may hold its own top-level `+`.
            elsif ["(", "{", "["].include?(char)
              depth += 1
            elsif [")", "}", "]"].include?(char)
              depth -= 1
            elsif char == "+" && depth.zero?
              return [expr[0...index].strip, expr[(index + 1)..].strip]
            end
          end
          nil
        end

        # Integer is signed 64-bit; a sum outside the range is an evaluation fault (C3.3, C3.4).
        INT64_RANGE = (-(2**63))..((2**63) - 1)

        def add(left, right)
          lhs = require_number(left, "addition")
          rhs = require_number(right, "addition")
          sum = lhs + rhs
          if sum.is_a?(Integer)
            return sum if INT64_RANGE.cover?(sum)

            raise EvaluationError, "addition overflowed: #{lhs} + #{rhs} does not fit in a 64-bit integer"
          end
          return sum if sum.finite?

          raise EvaluationError, "addition overflowed: #{lhs} + #{rhs} is not a finite number"
        end

        def quoted?(expr)
          return false if expr.length < 2

          (expr.start_with?('"') && expr.end_with?('"')) ||
            (expr.start_with?("'") && expr.end_with?("'"))
        end

        # Held equal to Vocabulary::SizedType by spec/vocabulary_conformance_spec.
        SIZED_TYPES = Hecks::Vocabulary.fetch("SizedType")

        def size_of(value)
          return value.size if value.is_a?(Array) || value.is_a?(String) || value.is_a?(Hash)

          raise EvaluationError, "size expects a list or string, got #{describe(value)}"
        end

        def emptiness_of(value)
          return value.empty? if value.is_a?(Array) || value.is_a?(String) || value.is_a?(Hash)

          raise EvaluationError, "empty? expects a list or string, got #{describe(value)}"
        end

        def split_value(value, separator)
          raise EvaluationError, "split expects a string, got #{describe(value)}" unless value.is_a?(String)

          value.split(separator)
        end

        def last_of(value)
          return value.last if value.respond_to?(:last)

          raise EvaluationError, "last expects a list, got #{describe(value)}"
        end

        def first_of(value)
          return value.first if value.respond_to?(:first)

          raise EvaluationError, "first expects a list, got #{describe(value)}"
        end

        def starts_with?(value, substring)
          raise EvaluationError, "start_with? expects a string, got #{describe(value)}" unless value.is_a?(String)

          value.start_with?(substring)
        end

        def ends_with?(value, substring)
          raise EvaluationError, "end_with? expects a string, got #{describe(value)}" unless value.is_a?(String)

          value.end_with?(substring)
        end

        # Held equal to Vocabulary::ToStringType by spec/vocabulary_conformance_spec.
        TO_STRING_TYPES = Hecks::Vocabulary.fetch("ToStringType")

        def string_of(value)
          case value
          when String then value
          when Integer, Float, TrueClass, FalseClass then value.to_s
          when NilClass then ""
          else
            raise EvaluationError, "to_s expects a scalar, got #{describe(value)}"
          end
        end

        def match_suffix(expr, suffixes)
          suffixes.each do |suffix|
            marker = ".#{suffix}"
            return [expr[0...-marker.length], suffix] if expr.end_with?(marker)
          end
          nil
        end

        def apply_sign_test(node, value)
          number = numeric(value)
          raise EvaluationError, "#{node.test} expects a number, got #{describe(value)}" unless number

          Evaluator.apply(node.operator, number, 0)
        end

        # Finds the outermost `marker` call whose matching `)` ends `expr`. `rindex` would split
        # nested `.modulo(` calls at the inner one, and a first match alone mis-parses chains.
        def match_call(expr, marker)
          start = 0
          while (index = expr.index(marker, start))
            close = matching_paren(expr, index + marker.length)
            return [expr[0...index], expr[(index + marker.length)...close]] if close == expr.length - 1

            start = index + 1
          end
          nil
        end

        def matching_paren(expr, start)
          depth = 1
          quote = nil
          index = start
          while index < expr.length
            char = expr[index]
            if quote
              quote = nil if char == quote
            elsif ['"', "'"].include?(char)
              quote = char
            elsif char == "("
              depth += 1
            elsif char == ")"
              depth -= 1
              return index if depth.zero?
            end
            index += 1
          end
          nil
        end

        # The zero-check reads the coerced divisor, not the raw value or a `to_i` truncation.
        def apply_modulo(receiver_value, divisor_value)
          receiver = require_number(receiver_value, "modulo")
          divisor  = require_number(divisor_value, "modulo")
          raise EvaluationError, "divided by 0" if divisor.zero?

          receiver % divisor
        end

        def lookup(expr, state, attrs)
          return unwrap_scalar(fetch(expr, state, attrs)) unless expr.include?(".")

          head, *rest = expr.split(".")
          unwrap_scalar(walk_path(fetch(head, state, attrs), rest))
        end

        # Walks dotted segments through a Hash-like value. `key?` picks the symbol or string
        # spelling so a held `false` is not mistaken for an absent key.
        def walk_path(value, segments)
          segments.reduce(value) do |current, segment|
            break nil unless current.respond_to?(:[])

            if current.is_a?(Hash)
              sym = segment.to_sym
              current.key?(sym) ? current[sym] : current[segment]
            else
              begin
                current[segment]
              rescue TypeError
                # `Array#[]` raises a raw TypeError for a String segment; refuse it instead.
                raise EvaluationError,
                      "cannot read #{segment.inspect} from #{describe(current)}"
              end
            end
          end
        end

        # Unwraps a single-field value object to its scalar so `field == "literal"` works.
        # Gated on the field count, not its name. Mirrors `impl Fielded for Json` in
        # rust/src/kernel/json.rs; change both together.
        def unwrap_scalar(value)
          return value unless value.respond_to?(:to_h) && !value.is_a?(Hash) && !value.is_a?(Array)

          if value.respond_to?(:value_object)
            sole = value.value_object.sole_attribute
            return sole ? value[sole.name] : value
          end

          hash = value.to_h
          hash.size == 1 && hash.key?(:value) ? hash[:value] : value
        end

        def fetch(name, state, attrs)
          key = name.to_sym
          return attrs[key] if attrs.key?(key)
          return state[key] if known?(state, key)

          raise EvaluationError, "cannot resolve #{name.inspect} — no such attribute or argument"
        end

        def known?(state, key)
          return state.key?(key) if state.respond_to?(:key?)

          !state[key].nil?
        end

        def numeric(value)
          value if value.is_a?(Integer) || value.is_a?(Float)
        end

        def require_number(value, operation)
          numeric(value) ||
            raise(EvaluationError, "#{operation} expects a number, got #{describe(value)}")
        end

        def describe(value) = Rendering.describe(value)
      end
    end
  end
end
