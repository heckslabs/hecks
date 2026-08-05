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
          seal_cursor
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

        private

        # `cursor` parses, round-trips through the IR, and is read by nothing —
        # no interpreter (Memory, Sqlite, Postgres) ever applies it. Refusing
        # it here, rather than deleting the word, keeps the declared syntax
        # honest (the language still knows the shape) while refusing to let a
        # bluebook author believe cursor-based pagination actually happens.
        def seal_cursor
          return unless @cursor

          raise Malformed,
                "#{@name} declares cursor, but no interpreter implements cursor " \
                "pagination — use limit/offset instead"
        end
      end
    end
  end
end
