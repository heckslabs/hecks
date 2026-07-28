module Hecksagain
  module Bluebook
    module DSL
      class QueryBuilder
        include AttributeCollector

        COMPARATORS = %i[eq ne gt gte lt lte in contains].freeze

        def initialize(name)
          @name   = name
          @wheres = []
        end

        def description(value) = @description = value

        def where(clauses)
          clauses.each do |field, value|
            op, operand = split_comparator(value)
            @wheres << IR::WhereClause.new(field: field, op: op, value: operand)
          end
        end

        def order_by(field, direction = :asc)
          @order_by = IR::OrderBy.new(field: field, direction: direction)
        end

        def limit(value) = @limit = IR::LimitSpec.new(value: value)

        def build
          IR::Query.new(
            name:        @name,
            description: @description,
            attributes:  attributes,
            wheres:      @wheres,
            order_by:    @order_by,
            limit:       @limit
          )
        end

        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        def split_comparator(value)
          return [:eq, value] unless value.is_a?(Hash)

          op, operand = value.first
          unless value.size == 1 && COMPARATORS.include?(op.to_sym)
            raise ArgumentError,
                  "unknown comparator #{value.inspect} — expected one of " \
                  "#{COMPARATORS.join(', ')}"
          end

          [op.to_sym, operand]
        end
      end
    end
  end
end
