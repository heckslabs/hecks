module Hecks
  module Bluebook
    module DSL
      class CommandBuilder
        # Lets a bluebook write arithmetic where a `sets` takes its source: inside a command, a bare
        # name that is one of its arguments or one of its owner's fields reads as an operand, and
        # `+ - * /` over operands and numbers build a {Hecks::Computed}.
        #
        #     sets :refund_cents, to: paid_cents * late_percent / 100
        module Operands
          # One node of the arithmetic a `sets` source spells: an operand name, a number, or two
          # nodes joined by an operator. Renders the canonical text the expression grammar reads,
          # parenthesised only where the written grouping needs it.
          class Computation
            # Binding strength of each operator; `*` and `/` bind tighter than `+` and `-`.
            PRECEDENCE = { :+ => 1, :- => 1, :* => 2, :/ => 2 }.freeze

            attr_reader :operator, :left, :right

            # @param operator [Symbol, nil] the joining operator, or nil for a name or number
            # @param left [Object] the operand name or number, or the left node
            # @param right [Object, nil] the right node of a joined pair
            def initialize(operator, left, right = nil)
              @operator = operator
              @left = left
              @right = right
            end

            PRECEDENCE.each_key do |operator|
              define_method(operator) { |other| Computation.new(operator, self, Computation.wrap(other)) }
            end

            # Lets `100 * paid` work: Ruby asks the right-hand operand to coerce the number.
            #
            # @return [Array<Computation>] the number and this node, as a left and right pair
            def coerce(number) = [Computation.wrap(number), self]

            # @return [Hecks::Computed, Symbol, Numeric] the source a `sets` records: the canonical
            #   text of joined arithmetic, or for a lone operand its argument name, or its number
            def to_source
              return Computed.new(to_text) if operator

              return left if left.is_a?(Numeric)

              path? ? Computed.new(left.to_s) : left.to_sym
            end

            # Reaches a field of the value object a name holds: `charged.cents` is the operand
            # `charged` followed by its field `cents`, read by the same dotted path a `given` reads.
            #
            # @return [Computation] the operand extended by one path segment
            def method_missing(field, *args, &block)
              return super unless field_read?(args, block)

              Computation.new(nil, "#{left}.#{field}")
            end

            def respond_to_missing?(field, include_private = false) = field_read?([], nil) || super

            # @return [Boolean] whether this operand is a dotted path into a value object
            def path? = left.to_s.include?(".")

            # @return [String] the expression text, such as `paid * rate / 100`
            def to_text
              return operand_text unless operator

              "#{side_text(left, false)} #{operator} #{side_text(right, true)}"
            end

            # @param value [Computation, Numeric] a node or a number
            # @return [Computation] the node, or the number wrapped as one
            # @raise [Bluebook::DSL::Malformed] if `value` is neither
            def self.wrap(value)
              return value if value.is_a?(Computation)
              return new(nil, value) if value.is_a?(Numeric)

              raise Malformed, "a sets expression joins argument names and numbers, not #{value.inspect}"
            end

            private

            def operand_text = left.to_s

            # Only a bare name (or an existing path) can be followed by a field.
            def field_read?(args, block) = operator.nil? && !left.is_a?(Numeric) && args.empty? && block.nil?

            # A joined side is parenthesised when it binds looser than this operator, or equally
            # on the right, so the printed text parses back to the same grouping.
            def side_text(side, right_side)
              return side.to_text unless side.operator

              looser = PRECEDENCE.fetch(side.operator) < PRECEDENCE.fetch(operator)
              equal_on_right = right_side && PRECEDENCE.fetch(side.operator) == PRECEDENCE.fetch(operator)
              looser || equal_on_right ? "(#{side.to_text})" : side.to_text
            end
          end

          private

          # A bare name the command declares as an argument, or its owner declares as a field,
          # is an operand; anything else keeps the builder's own answer.
          def method_missing(word, *args, **kwargs, &block)
            return Computation.new(nil, word) if operand?(word, args, kwargs, block)

            super
          end

          def respond_to_missing?(word, include_private = false)
            operand?(word, [], {}, nil) || super
          end

          def operand?(word, args, kwargs, block)
            return false unless args.empty? && kwargs.empty? && block.nil?

            attributes.any? { |attr| attr.name == word } || @owner_attributes.any? { |attr| attr.name == word }
          end
        end
      end
    end
  end
end
