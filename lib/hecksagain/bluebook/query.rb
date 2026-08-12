require_relative "behaviour/query"

module Hecksagain
  module Bluebook
    def self.render_value(value) = Literal.render(value)

    # A query — an ASK, declared on an aggregate or on one of its entities.
    #
    # It crosses over as an INSTANCE rather than a class, and the reason is worth
    # stating because it is the boundary of the pattern. A query inherits its
    # whole body from `QuerySpecification::Common::Options` — `wheres`,
    # `order_by`, `limit`, `offset`, `cursor`, `consistency`, `freshness`,
    # `authorization`, `null_semantics`, `inspection`, `index_hints` — and those
    # are INSTANCE methods that the runtime and the SQLite adapter both read.
    # Hoisting the declaration onto a metaclass would put the identity and the
    # specification on opposite sides of the object.
    #
    # And nothing is lost, because `Class#name` was the only reason a construct
    # ever needed a second word for its own name. An instance answers `name`
    # truthfully. So a query gains an owner and an identity — which is what the
    # graph is for — and keeps the name it always had.
    class Query < QuerySpecification::Common::Options
      include Construct

      include Hecksagain::IR
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

      def initialize(name:, description: nil, attributes: [], wheres: [],
                     order_by: nil, limit: nil, offset: nil, cursor: nil,
                     consistency: nil, freshness: nil, authorization: nil, null_semantics: nil,
                     inspection: nil, index_hints: [])
        null_semantics ||= QuerySpecification::Common::NullSemantics.default
        super(wheres: wheres, order_by: order_by, limit: limit, offset: offset, cursor: cursor,
              consistency: consistency, freshness: freshness, authorization: authorization,
              null_semantics: null_semantics, inspection: inspection, index_hints: index_hints)
        @name        = name.to_s
        @hecks_name  = @name
        @description = description
        @attributes  = attributes
      end


      # A query's shape is NOT fixed — `extra_options_to_h` carries
      # whatever options the specification layer grew (count, median,
      # group_by, scope_to). Declared emission covers the settled part
      # and `super` hands it over; the tail stays dynamic, which is the
      # honest description of it.
      def to_h = super.merge(extra_options_to_h)
    end
  end
end
