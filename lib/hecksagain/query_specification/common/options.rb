require_relative "null_semantics"

module Hecksagain
  module QuerySpecification
    module Common
      class Options
        attr_reader :wheres, :order_by, :limit, :offset, :cursor, :consistency, :freshness,
                    :authorization, :null_semantics, :inspection, :index_hints

        def initialize(wheres: [], order_by: nil, limit: nil, offset: nil, cursor: nil,
                       consistency: nil, freshness: nil, authorization: nil,
                       inspection: nil, null_semantics: NullSemantics.default, index_hints: [])
          @wheres, @order_by, @limit, @offset, @cursor = wheres, order_by, limit, offset, cursor
          @consistency, @freshness = consistency, freshness
          @authorization, @null_semantics, @inspection, @index_hints = authorization, null_semantics, inspection, index_hints
        end

        def options_to_h
          { wheres: @wheres.map(&:to_h), order_by: @order_by&.to_h, limit: @limit&.to_h,
            offset: @offset&.to_h, cursor: @cursor&.to_h, consistency: @consistency&.to_h,
            freshness: @freshness&.to_h, authorization: @authorization&.to_h,
            null_semantics: @null_semantics&.to_h, inspection: @inspection&.to_h,
            index_hints: @index_hints.map(&:to_h) }
        end

        def extra_options_to_h
          options_to_h.reject { |key, value| value.nil? || value == [] || (key == :null_semantics && value == { mode: "native" }) }
                         .reject { |key, _| %i[wheres order_by limit].include?(key) }
        end
      end
    end
  end
end
