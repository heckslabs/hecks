require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses a `query "Name" do ... end` block, declared on an aggregate
      # or one of its entities, into a `Query` — its own parameters (plain
      # attributes, including reference-typed ones) plus whatever `where`/
      # `order_by`/`limit`/etc. `QuerySpecification::Common::DSL` contributes.
      # A block parameter naming an already-declared owner attribute has its
      # type derived from the owner rather than restated (`derive_from_owner!`).
      class QueryBuilder
        GRAMMAR_CONTEXT = "Query".freeze

        include AttributeCollector
        include QuerySpecification::Common::DSL
        include WordGate

        # @param name [String] the query's name, as written after `query`
        def initialize(name)
          @name   = name
          @wheres = []
        end

        # Sets the human-readable description shown for this query.
        #
        # @param value [String] the description text
        # @return [String] the description as stored
        def description(value) = @description = value

        # Hands the query to a port's bound adapter, instead of a scan over the aggregate's records.
        #
        # The adapter is asked by the query's snake-cased name with the query's arguments, and
        # whatever it answers is the query's result; the aggregate is never read.
        #
        # @param port [String] the port's name, as its adapter's `.adapter` declaration spells it
        # @return [QuerySpecification::Common::AnsweredBySpec] the port just recorded
        def answered_by(port) = @answered_by = QuerySpecification::Common::AnsweredBySpec.new(port: port)

        # Declares a query parameter that names another aggregate's identity.
        #
        # A plain attribute typed as a reference; a query has no root of its own to act on.
        # Reached through `calls: "reference_to_impl"`.
        #
        # @param type [Module, Symbol, String] the referenced aggregate, written as a bare
        #   constant
        # @param as [Symbol, nil] the parameter's name; nil derives it from the target
        # @param optional [Boolean] whether the parameter may be omitted when the query runs
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if `as` (or the derived name) is already declared
        def reference_to_impl(type, as: nil, optional: false)
          target = Naming.demodulise(type)
          attribute_impl(as || default_reference_name(target), Reference.new(target), optional: optional)
        end

        # Assembles the declared parameters and filtering into a `Query`.
        #
        # @return [Bluebook::Query] the built query
        # @raise [Bluebook::DSL::Malformed] if the body declares `cursor`, which no interpreter
        #   implements
        def build
          seal_cursor
          Query.new(
            name:           @name,
            description:    @description,
            attributes:     attributes,
            wheres:         @wheres,
            order_by:       @order_by,
            limit:          @limit,
            offset:         @offset,
            cursor:         @cursor,
            authorization:  @authorization,
            null_semantics: @null_semantics,
            inspection:     @inspection,
            answered_by:    @answered_by
          )
        end

        # Evaluates a `query` block against a fresh builder, then fills in owner-derived types.
        #
        # @param name [String] the query's name
        # @param owner_attributes [Array<Bluebook::Attribute>] the enclosing aggregate or
        #   entity's own attributes, matched against the block's own parameter names
        # @yield the query body, evaluated with the builder as `self`; may be omitted
        # @return [Bluebook::Query] the built query
        # @raise [Bluebook::DSL::Malformed] if the body declares `cursor`, a duplicate attribute,
        #   or a filtering clause the query language refuses
        def self.build(name, owner_attributes: [], &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          # `send`: `derive_from_owner!` is internal wiring, not a DSL word, so it stays private
          # (syntax_conformance_spec).
          builder.send(:derive_from_owner!, owner_attributes, block) if block
          builder.build
        end

        private

        # Fills in a block parameter that names an owner attribute (`query "X" do |decision|`)
        # with the owner's type, unless the body declared it. Unmatched names are left for
        # MetaValidator's unresolved-attribute check.
        def derive_from_owner!(owner_attributes, block)
          block.parameters.each do |kind, param_name|
            next unless %i[req opt].include?(kind)
            next if attributes.any? { |a| a.name == param_name }

            owner_attr = owner_attributes.find { |a| a.name == param_name }
            next unless owner_attr

            # `Attribute.new` directly: `owner_attr.type` is already spelled, so it must not go
            # through the quoted-type refusal meant for DSL source text.
            attributes << Attribute.new(name: param_name, type: owner_attr.type, optional: owner_attr.optional?)
          end
        end

        # `cursor` parses and round-trips but no interpreter applies it; refuse it so an author
        # does not believe cursor pagination happens.
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
