# QueryBuilder — evaluates a `query "ByAuthor" do ... end` block.
#
# The DSL surface is Hecks's — `where`, `order_by`, `limit`, and `attribute` for
# the query's own inputs. What differs is WHEN the block runs.
#
# Hecks keeps the block and evaluates it at read time. Here it is evaluated ONCE,
# now, against this recorder, and only data survives : a Proc in the IR is the
# one thing expression.bluebook forbids outright, because Rust cannot run it and
# no target can read it.
#
#   query "Available" do
#     where(status: "available")
#     order_by :name
#     limit 10
#   end
#
#   query "ByAuthor" do
#     attribute :author, String
#     where(author: :author)     # a :symbol names one of this query's inputs
#   end
module Hecksagain
  module Bluebook
    module DSL
      class QueryBuilder
        include AttributeCollector

        # `where(field: value)` for equality, or `where(field: { gt: 5 })` for
        # an ordered comparison. The hash form is how a comparator reaches the
        # DSL without inventing operator methods.
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

        # `order_by :title` ascends ; `order_by :title, :desc` flips it.
        def order_by(field, direction = :asc)
          @order_by = IR::OrderBy.new(field: field, direction: direction)
        end

        # A literal cap, or a :symbol naming one of this query's inputs.
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

        # A bare value is equality. A single-pair hash whose key is a known
        # comparator is that comparison ; anything else RAISES rather than being
        # read as a literal hash, because a misspelled comparator that silently
        # became an equality check against "{gte: 5}" is a filter that quietly
        # matches nothing.
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
