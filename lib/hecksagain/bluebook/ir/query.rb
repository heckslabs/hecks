module Hecksagain
  module Bluebook
    module IR
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
