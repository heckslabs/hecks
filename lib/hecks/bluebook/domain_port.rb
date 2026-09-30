require_relative "behaviour/domain_port"

module Hecks
  module Bluebook
    # One operation on a driving port: an external call turned into an event in this domain.
    #
    # Carries no `given`/`ensures`/`then_set`; those stay on the command a `policy` triggers.
    class PortOperation
      include Hecks::IR
      include Behaviour::PortOperation

      emits_ir(name: :hecks_name, attributes: many(:attributes), emits: :emits)

      attr_reader :hecks_name, :attributes, :emits, :direction, :answers, :refuses, :to

      # `:inbound` (`tells`) is an external fact arriving as an event; it emits and nothing more.
      # `:outbound` (`asks`) is the domain wanting something from outside, naming both
      # `answers` and `refuses` so the failure is visible to the model.
      #
      # @param name [String, Symbol] the operation's declared name
      # @param attributes [Array<Bluebook::Attribute>] the declared payload fields
      # @param emits [Array<String>] the events an inbound operation records
      # @param direction [Symbol, String] `:inbound` or `:outbound`
      # @param answers [String, nil] an outbound operation's event for the adapter's answer
      # @param refuses [String, nil] an outbound operation's event for the adapter's refusal
      # @param to [String, nil] the aggregate this operation routes to, if any
      def initialize(name:, attributes: [], emits: [], direction: :inbound, answers: nil, refuses: nil, to: nil)
        @hecks_name = name.to_s
        @attributes = attributes
        @emits      = emits
        @direction  = direction.to_sym
        @answers    = answers
        @refuses    = refuses
        @to         = to
        @attributes_by_name = attributes.to_h { |attribute| [attribute.name, attribute] }
      end

      # Says whether this operation is the domain asking something of an adapter.
      #
      # @return [Boolean] whether this operation is an `asks`
      def outbound? = @direction == :outbound

      # Says whether this operation is an adapter telling the domain something.
      #
      # @return [Boolean] whether this operation is a `tells`/`operation`
      def inbound?  = @direction == :inbound

      # `direction`/`answers`/`refuses`/`to` are merged in only when set: the Rust parser
      # emits none of them, so an unconditional key would break parser_parity_spec.
      #
      # @return [Hash] the declared emission, plus `direction`/`answers`/`refuses` for an
      #   outbound operation and `to` when a routing target is declared
      def to_h
        shape = super
        shape = shape.merge(direction: @direction.to_s, answers: @answers, refuses: @refuses) unless inbound?
        shape = shape.merge(to: @to) if @to
        shape
      end
    end

    # A query the hecksagon binds to a port's adapter: the bluebook declares the question, and
    # this declares that something outside the domain answers it, and in what shape.
    class QueryAnswer
      include Hecks::IR

      # The shapes an adapter's answer may take: one document of text, one row, or many rows.
      SHAPES = %i[text row rows].freeze

      emits_ir(name: :name, shape: :shape_name)

      attr_reader :name, :shape

      # @param name [String, Symbol] the bound query's declared name
      # @param shape [Symbol, String] `:text`, `:row` or `:rows`
      # @raise [Bluebook::DSL::Malformed] if `shape` is none of `SHAPES`
      def initialize(name:, shape:)
        @name  = name.to_s
        @shape = shape.to_sym
        return if SHAPES.include?(@shape)

        raise DSL::Malformed, "#{@name} answers as #{shape.inspect} — a query answer is one of " \
                              "#{SHAPES.map(&:inspect).join(', ')}"
      end

      # @return [String] the shape as written in the IR
      def shape_name = @shape.to_s
    end

    # A named group of operations an aggregate exposes to whatever adapter calls in, plus the
    # queries its adapter answers.
    class DomainPort
      include Hecks::IR
      include Behaviour::DomainPort

      emits_ir(name: :name, operations: many(:operations))

      attr_reader :name, :operations, :answered_queries

      # @param name [String, Symbol] the port's declared name
      # @param operations [Array<Bluebook::PortOperation>] the port's declared operations
      # @param answered_queries [Array<Bluebook::QueryAnswer>] the queries this port's adapter
      #   answers instead of the aggregate's stored records
      def initialize(name:, operations: [], answered_queries: [])
        @name             = name.to_s
        @operations       = operations
        @answered_queries = answered_queries
      end

      # `answered_queries` is merged in only when there are some, so a port that binds no query
      # emits the shape it always did.
      #
      # @return [Hash] the port's IR
      def to_h
        shape = super
        return shape if @answered_queries.empty?

        shape.merge(answered_queries: @answered_queries.map(&:to_h))
      end
    end
  end
end
