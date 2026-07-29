module Hecksagain
  module Bluebook
    module DSL
      class QueryBuilder
        include AttributeCollector
        include QuerySpecification::Common::DSL

        def initialize(name)
          @name   = name
          @wheres = []
          @index_hints = []
        end

        def description(value) = @description = value

        def build
          IR::Query.new(
            name:        @name,
            description: @description,
            attributes:  attributes,
            wheres:      @wheres,
            order_by:    @order_by,
            limit:       @limit,
            offset:      @offset,
            cursor:      @cursor,
            consistency: @consistency,
            freshness: @freshness,
            authorization: @authorization,
            null_semantics: @null_semantics,
            inspection: @inspection,
            index_hints: @index_hints || []
          )
        end

        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end

      end
    end
  end
end
