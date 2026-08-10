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

        # A query parameter naming another aggregate's own identity —
        # Item.ByOwner's `owner`, filtering by which Camper owns it,
        # not a free string that only happens to look like one. Only
        # ever the CROSS-reference half `CommandBuilder#reference_to`
        # has two of: a query has no root of its own to act on, so
        # there's no "acts on itself" case to distinguish here, only a
        # plain attribute typed as a reference —
        # `AttributeCollector#attribute` already handles an
        # `IR::Reference` type exactly like any other.
        def reference_to(type, as: nil, optional: false)
          demodulised = Naming.demodulise(type)
          attribute(as || :"#{Naming.snake(demodulised)}_id", IR::Reference.new(demodulised), optional: optional)
        end

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
