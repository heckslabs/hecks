require_relative "behaviour/query"

module Hecks
  # Reopened here only to add `render_value` below — the pinned
  # wire-literal rendering (`Literal.render`) the `emits_ir` Procs
  # throughout this chapter reach for. See lib/hecks/bluebook.rb's own
  # header for what `Bluebook` is as a whole.
  module Bluebook
    # Renders a captured Ruby value to its self-describing wire spelling.
    #
    # @param value [Object] any value an `emits_ir` field carries, such as a Symbol,
    #   String, Hash, Array, or literal
    # @return [String] the value rendered through `Hecks::Literal.render`
    def self.render_value(value) = Literal.render(value)

    # A query — an ask, declared on an aggregate or on one of its entities.
    #
    # It crosses over as an instance rather than a class, and the reason is worth
    # stating because it is the boundary of the pattern. A query inherits its
    # whole body from `QuerySpecification::Common::Options` — `wheres`,
    # `order_by`, `limit`, `offset`, `cursor`,
    # `authorization`, `null_semantics`, `inspection` — and those
    # are instance methods that the runtime and the SQLite adapter both read.
    # Hoisting the declaration onto a metaclass would put the identity and the
    # specification on opposite sides of the object.
    #
    # And nothing is lost, because `Class#name` was the only reason a construct
    # ever needed a second word for its own name. An instance answers `name`
    # truthfully. So a query gains an owner and an identity — which is what the
    # graph is for — and keeps the name it always had.
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

      # @param name [String, Symbol] the query's declared name
      # @param description [String, nil] the query's declared prose description
      # @param attributes [Array<Bluebook::Attribute>] the query's declared result fields
      # @param wheres [Array<QuerySpecification::Common::WhereClause>] the declared filter
      #   conditions
      # @param order_by [QuerySpecification::Common::OrderBy, nil] the declared sort field
      #   and direction, or `nil` for no explicit ordering
      # @param limit [QuerySpecification::Common::LimitSpec, nil] the declared row limit,
      #   or `nil` for none
      # @param offset [QuerySpecification::Common::OffsetSpec, nil] the declared row offset,
      #   or `nil` for none
      # @param cursor [QuerySpecification::Common::CursorSpec, nil] the declared pagination
      #   cursor, or `nil` for none
      # @param authorization [QuerySpecification::Common::AuthorizationSpec, nil] the declared
      #   authorization policy, or `nil` for none
      # @param null_semantics [QuerySpecification::Common::NullSemantics, nil] how this query
      #   orders `nil` values; defaults to `NullSemantics.default` when omitted
      # @param inspection [QuerySpecification::Common::InspectionSpec, nil] the declared
      #   inspection mode, or `nil` for none
      def initialize(name:, description: nil, attributes: [], wheres: [],
                     order_by: nil, limit: nil, offset: nil, cursor: nil,
                     authorization: nil, null_semantics: nil,
                     inspection: nil)
        null_semantics ||= QuerySpecification::Common::NullSemantics.default
        super(wheres: wheres, order_by: order_by, limit: limit, offset: offset, cursor: cursor,
              authorization: authorization,
              null_semantics: null_semantics, inspection: inspection)
        @name        = name.to_s
        @hecks_name  = @name
        @description = description
        @attributes  = attributes
      end

      # A query's shape is not fixed — `extra_options_to_h` carries
      # whatever options the specification layer grew (count, median,
      # group_by, scope_to). Declared emission covers the settled part
      # and `super` hands it over; the tail stays dynamic, which is the
      # honest description of it.
      #
      # @return [Hash] the declared emission, merged with whatever `extra_options_to_h`
      #   the specification layer currently carries
      def to_h = super.merge(extra_options_to_h)
    end
  end
end
