require_relative "behaviour/query"

module Hecks
  # Reopened to add `render_value`, the wire-literal rendering `emits_ir` procs use.
  module Bluebook
    # Renders a captured value to its wire spelling through `Hecks::Literal.render`.
    def self.render_value(value) = Literal.render(value)

    # A query — an ask, declared on an aggregate or on one of its entities.
    #
    # It crosses over as an instance, not a class: its body comes from
    # `QuerySpecification::Common::Options`, whose instance methods the runtime reads.
    class Query < QuerySpecification::Common::Options
      include Construct

      include Hecks::IR
      include Behaviour::Query

      emits_ir(
        name:        :name,
        description: :description,
        attributes:  many(:attributes),
        wheres:      many(:wheres),
        order_by:    one(:order_by),
        limit:       one(:limit)
      )

      attr_reader :name, :description, :attributes

      # @param null_semantics [QuerySpecification::Common::NullSemantics, nil] defaults to
      #   `NullSemantics.default`
      def initialize(name:, description: nil, attributes: [], wheres: [],
                     order_by: nil, limit: nil, offset: nil, cursor: nil,
                     authorization: nil, null_semantics: nil,
                     inspection: nil, answered_by: nil)
        null_semantics ||= QuerySpecification::Common::NullSemantics.default
        super(wheres: wheres, order_by: order_by, limit: limit, offset: offset, cursor: cursor,
              authorization: authorization,
              null_semantics: null_semantics, inspection: inspection, answered_by: answered_by)
        @name        = name.to_s
        @hecks_name  = @name
        @description = description
        @attributes  = attributes
      end

      # `extra_options_to_h` (count, median, group_by, scope_to) stays dynamic; `super` covers the
      # declared emission.
      #
      # @return [Hash] the declared emission merged with `extra_options_to_h`
      def to_h = super.merge(extra_options_to_h)
    end
  end
end
