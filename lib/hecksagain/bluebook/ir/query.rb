module Hecksagain
  module Bluebook
    module IR
      def self.render_value(value) = QuerySpecification.render_value(value)

      class Query < QuerySpecification::Common::Options

        # The BLUEBOOK's name for this construct, asked the same way of a class
        # that has crossed over and of an IR object that has not. Collapses into
        # Construct when this one crosses.
        def hecks_name = @name
        attr_reader :name, :description, :attributes

        def initialize(name:, description: nil, attributes: [], wheres: [],
                       order_by: nil, limit: nil, offset: nil, cursor: nil,
                       consistency: nil, freshness: nil, authorization: nil, null_semantics: nil,
                       inspection: nil, index_hints: [])
          null_semantics ||= QuerySpecification::Common::NullSemantics.default
          super(wheres: wheres, order_by: order_by, limit: limit, offset: offset, cursor: cursor,
                consistency: consistency, freshness: freshness, authorization: authorization,
                null_semantics: null_semantics, inspection: inspection, index_hints: index_hints)
          @name        = name.to_s
          @description = description
          @attributes  = attributes
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
          }.merge(extra_options_to_h)
        end
      end
    end
  end
end
