require "base64"
require "delegate"
require "json"
require_relative "../../query_specification/field_path"
require_relative "../../query_specification/common/comparison"
require_relative "../../query_specification/common/limit_spec"

module Hecks
  module Ports
    module Query
      # The position a cursor query pages by: the row's order value and its identity, as one opaque
      # token, and the rule for which rows follow it.
      #
      # The sequence is the one `Ordering` and `NullPolicy.sql_order` give: the order field in the
      # declared direction, nulls where `nulls` puts them, identity breaking ties in the same
      # direction. `SqlKeyset` compiles the same rule into SQL.
      module Cursor
        # A token the query did not hand out.
        class Invalid < ArgumentError; end

        # The decoded position: the order field's comparable value (nil when null) and the row id.
        Position = Struct.new(:value, :id)

        # A declared query that asks for one row more than its page, to learn whether another follows.
        class Widened < SimpleDelegator
          # @param declared [QuerySpecification::Common::Options] the cursor query
          # @param size [Integer] the page size the query's `limit` resolves to
          def initialize(declared, size)
            super(declared)
            @limit = QuerySpecification::Common::LimitSpec.new(value: size + 1)
          end

          # @return [QuerySpecification::Common::LimitSpec] the page size plus one
          attr_reader :limit
        end

        module_function

        # @param value [Object, nil] the row's comparable order value
        # @param id [String] the row's identity
        # @return [String] the URL-safe token naming that position
        def encode(value, id) = Base64.urlsafe_encode64(JSON.generate([json_safe(value), id.to_s]), padding: false)

        # @param token [String, nil] an `after` argument
        # @return [Position, nil] the position, or nil when there is no token
        # @raise [Invalid] if the token is not one `encode` made
        def decode(token)
          return nil if token.nil? || token.to_s.empty?

          value, id = JSON.parse(Base64.urlsafe_decode64(token.to_s))
          raise Invalid, "after #{token.inspect} is not a cursor" unless id.is_a?(String)

          Position.new(value, id)
        rescue JSON::ParserError, ArgumentError, TypeError
          raise Invalid, "after #{token.inspect} is not a cursor this query handed out"
        end

        # Whether a null sorts before the valued rows in this query's order.
        def nulls_first?(direction, policy)
          case policy&.mode.to_s
          when "first" then true
          when "last" then false
          else direction.to_s.downcase != "desc"
          end
        end

        # @param rows [Array<Runtime::Instance, Hash>] rows already in query order
        # @param declared [QuerySpecification::Common::Options] a cursor query
        # @param args [Hash] the ask's arguments; `:after` carries the token
        # @return [Array] the rows following the token's position, all of them with no token
        def after(rows, declared, args)
          position = decode(args[:after])
          return rows unless position

          rows.select { |row| follows?(row, declared, position) }
        end

        # @return [Boolean] whether `row` comes after `position` in the query's order
        def follows?(row, declared, position)
          order_by = declared.order_by
          value = order_by && comparable_value(row, order_by.field)
          return (id_of(row) <=> position.id) == 1 unless order_by

          sequence(value, id_of(row), position, order_by, declared.null_semantics).positive?
        end

        # @return [Integer] -1, 0 or 1: where the row sits against the position in query order
        def sequence(value, id, position, order_by, policy)
          first = nulls_first?(order_by.direction, policy)
          return (value.nil? == first ? -1 : 1) if value.nil? != position.value.nil?

          result = ties_by_id(value.nil? ? 0 : value <=> position.value, id, position.id)
          order_by.direction.to_s.downcase == "desc" ? -result : result
        end

        # A tie in the order value (or two values that do not compare) falls to identity.
        def ties_by_id(compared, id, held_id) = compared.nil? || compared.zero? ? id <=> held_id : compared

        # The token naming the last of `rows`, with the page's ordering read off `declared`.
        def token_for(row, declared)
          order_by = declared.order_by
          encode(order_by && comparable_value(row, order_by.field), id_of(row))
        end

        # Splits rows fetched one past the page into the page and the token of the next one.
        #
        # @param rows [Array] up to `size + 1` rows in query order
        # @param declared [QuerySpecification::Common::Options] the cursor query, unwidened
        # @param size [Integer] the page size
        # @return [Array(Array, String, nil)] the page rows and `after`, nil on the last page
        def split(rows, declared, size)
          page = rows.first(size)
          [page, rows.size > size && !page.empty? ? token_for(page.last, declared) : nil]
        end

        def comparable_value(row, field)
          json_safe(QuerySpecification::Common::Comparison.comparable(QuerySpecification::FieldPath.dig(row, field)))
        end

        def id_of(row) = (row.is_a?(Hash) ? row[:id] : row.id).to_s

        def json_safe(value)
          case value
          when nil, String, Numeric, true, false then value
          else value.to_s
          end
        end
      end
    end
  end
end
