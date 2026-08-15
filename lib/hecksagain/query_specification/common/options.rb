require_relative "null_semantics"

module Hecksagain
  module QuerySpecification
    module Common
      class Options
        attr_reader :wheres, :order_by, :limit, :offset, :cursor,
                    :authorization, :null_semantics, :inspection

        def initialize(wheres: [], order_by: nil, limit: nil, offset: nil, cursor: nil,
                       authorization: nil,
                       inspection: nil, null_semantics: NullSemantics.default)
          @wheres, @order_by, @limit, @offset, @cursor = wheres, order_by, limit, offset, cursor
          @authorization, @null_semantics, @inspection = authorization, null_semantics, inspection
        end

        def options_to_h
          { wheres: @wheres.map(&:to_h), order_by: @order_by&.to_h, limit: @limit&.to_h,
            offset: @offset&.to_h, cursor: @cursor&.to_h, authorization: @authorization&.to_h,
            null_semantics: @null_semantics&.to_h, inspection: @inspection&.to_h }
        end

        def extra_options_to_h
          options_to_h.reject { |key, value| value.nil? || value == [] || (key == :null_semantics && value == { mode: "native" }) }
                         .reject { |key, _| %i[wheres order_by limit].include?(key) }
        end
      end
    end
  end
end
