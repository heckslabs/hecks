require_relative "../../ports/query/cursor"

module Hecks
  module Runtime
    class QueryInterpreter
      # Answers a cursor query a page at a time (ADR 0128). Mixed into {QueryInterpreter}.
      module Paging
        # Answers one page of a cursor query: the rows, and the token of the page after them.
        #
        # The query is asked for one row past its page; that row proves a next page exists and is
        # not answered.
        #
        # @param query_name [String] a declared aggregate query that declares `cursor`
        # @param args [Hash] the query's arguments; `:after` is the position, absent on page one
        # @return [Hash{Symbol => Object}] `rows` (frozen Hashes) and `after` (a String, nil on the
        #   last page)
        # @param page_size [Integer, nil] a page smaller than the query's own `limit`; never larger
        # @raise [ArgumentError] if the query has no cursor, or `after` is not a token it handed out
        def page(domain, aggregate, query_name, args, page_size: nil)
          declared = declared_query(aggregate, query_name)
          raise ArgumentError, "#{query_name} declares no cursor, so it has no pages" unless declared.cursor

          size = [declared_page_size(declared, normalize_args(aggregate, declared, args)), page_size || Float::INFINITY].min
          rows, after = Ports::Query::Cursor.split(call(domain, aggregate, query_name, args, widen: size), declared, size)
          { rows: rows, after: after }
        end

        private

        # The cursor's position, then offset, then limit. Offset comes before limit, as SQL's
        # `LIMIT n OFFSET m` and Ports::Query::InMemory do.
        def paginate(ordered, declared, args)
          ordered = Ports::Query::Cursor.after(ordered, declared, args) if declared.cursor
          skipped = declared.offset ? ordered.drop(resolve_query_value(declared.offset.value, args).to_i) : ordered
          declared.limit ? skipped.first(resolve_query_value(declared.limit.value, args).to_i) : skipped
        end

        def declared_page_size(declared, args) = resolve_query_value(declared.limit.value, args).to_i
      end
    end
  end
end
