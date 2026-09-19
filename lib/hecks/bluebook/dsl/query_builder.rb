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

        # Declares a query parameter that names another aggregate's identity.
        #
        # A query parameter naming another aggregate's own identity
        # (Card.Active's own `Board`, filtering to one board's cards) —
        # just a plain attribute typed as a reference,
        # `AttributeCollector#attribute_impl` already handling a Reference
        # exactly like any other. No "acts on itself" case to
        # distinguish here the way a command's own reference_to has —
        # a query has no root of its own to act on, only parameters.
        #
        # Answers the `reference_to` word through the table's `calls:`
        # column — item #13's full metaprogrammed dispatch (slice 4b).
        # Bootstrap-reachable, in `GenericDispatch::BOOTSTRAP_CALLS_FALLBACK`.
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
            inspection:     @inspection
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
          # `send`, not a public call — this isn't a bluebook DSL word (no
          # author ever writes `derive_from_owner!` inside a query block),
          # just internal wiring between this class method and the instance
          # it just built. Kept private below so syntax_conformance_spec's
          # own "every word QueryBuilder answers is declared" check doesn't
          # mistake it for one.
          builder.send(:derive_from_owner!, owner_attributes, block) if block
          builder.build
        end

        private

        # A block parameter names one of the owner's (the aggregate or entity
        # this query is declared on) own already-declared attributes —
        # `query "ForDecision" do |decision| where decision: :decision end`
        # on Submission, whose own `attribute :decision, DecisionRef` already
        # says what `decision` is. Restating `attribute :decision, DecisionRef`
        # a second time inside the query was pure duplication; this derives
        # the same type from the owner instead. Only fills in a name the block
        # body did not already declare explicitly (checked after instance_eval
        # runs, so an existing bluebook still spelling it out both ways keeps
        # working unchanged — this only removes the need to, never refuses
        # the choice to). A block parameter matching nothing on the owner is
        # left alone; MetaValidator's own unresolved-attribute check names it,
        # the same way a typo in a hand-written `attribute` call already does.
        def derive_from_owner!(owner_attributes, block)
          block.parameters.each do |kind, param_name|
            next unless %i[req opt].include?(kind)
            next if attributes.any? { |a| a.name == param_name }

            owner_attr = owner_attributes.find { |a| a.name == param_name }
            next unless owner_attr

            # `Attribute.new` directly, not the public `attribute(...)` DSL
            # entry — `owner_attr.type` is already spelled (a demodulised
            # String, `Attribute#spell`'s own doing), not a bareword the
            # bluebook author typed, so it must not run through
            # `AttributeCollector#attribute`'s quoted-type refusal (ADR
            # 0025, "Attributes") — that refusal exists for DSL source
            # text, not for a type already resolved elsewhere and copied.
            attributes << Attribute.new(name: param_name, type: owner_attr.type, optional: owner_attr.optional?)
          end
        end

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
