# Query — a named read over an aggregate's records.
#
# The read side of the domain. A query filters (`where`), orders (`order_by`),
# and caps (`limit`) ; it declares its own inputs as attributes, so a clause can
# reference a caller-supplied value by its symbol form and the runtime resolves
# it at dispatch.
#
#   query "ByAuthor" do
#     attribute :author, String
#     where(author: :author)
#     order_by :title
#     limit 10
#   end
#
# NO PROC LIVES HERE. Hecks stores the query block and evaluates it later ; a
# Proc in the IR is exactly what expression.bluebook exists to forbid — Rust
# cannot run it, SQL cannot push it down, no specializer can read it. The block
# is evaluated ONCE at build time against a recorder, and what survives is data.
module Hecksagain
  module Bluebook
    module IR
      # One filter clause. `op` is the comparison ; `value` is a literal or a
      # ":symbol" naming one of the query's own attributes.
      # A :symbol KEEPS ITS COLON when rendered. `where(price: :ceiling)` names
      # one of the query's inputs ; `where(price: "ceiling")` is the literal
      # string. Drop the marker and the two become the same document, and a
      # filter that was meant to read a caller's value silently compares against
      # the word instead.
      def self.render_value(value)
        value.is_a?(Symbol) ? ":#{value}" : value.to_s
      end

      WhereClause = Struct.new(:field, :op, :value, keyword_init: true) do
        def to_h = { field: field.to_s, op: op.to_s, value: IR.render_value(value) }
      end

      OrderBy = Struct.new(:field, :direction, keyword_init: true) do
        def to_h = { field: field.to_s, direction: direction.to_s }
      end

      LimitSpec = Struct.new(:value, keyword_init: true) do
        def to_h = { value: IR.render_value(value) }
      end

      class Query
        attr_reader :name, :description, :attributes, :wheres, :order_by, :limit

        def initialize(name:, description: nil, attributes: [], wheres: [],
                       order_by: nil, limit: nil)
          @name        = name.to_s
          @description = description
          @attributes  = attributes
          @wheres      = wheres
          @order_by    = order_by
          @limit       = limit
        end

        def attribute(named) = @attributes.find { |a| a.name == named.to_sym }

        def to_h
          {
            name:        @name,
            description: @description,
            attributes:  @attributes.map(&:to_h),
            wheres:      @wheres.map(&:to_h),
            order_by:    @order_by&.to_h,
            limit:       @limit&.to_h
          }
        end
      end
    end
  end
end
