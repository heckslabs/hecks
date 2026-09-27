module Hecks
  module Runtime
    # The invocation address (`to:`), kept apart from a command's domain payload.
    # Thin delegators to `Runtime::Invocation`, which reads a call's shape.
    module Routing
      Envelope = Struct.new(:aggregate, :entities, keyword_init: true) do
        # @param aggregate [String, #to_s] the receiving aggregate's identity
        # @param entities [Array<String, #to_s>, nil] the entity-hop identities after the
        #   aggregate, in call order; empty for an aggregate-level command
        def initialize(aggregate:, entities: [])
          super(aggregate: aggregate.to_s, entities: Array(entities).map(&:to_s).freeze)
          freeze
        end
      end

      module_function

      # Resolves a `to:` argument into a routing envelope (see `Invocation.route`).
      #
      # @param to [String, Hash, nil] a bare aggregate identity, or a Hash with
      #   `aggregate:` and `entity:`/`entities:`; nil for no receiver
      # @param entity_depth [Integer] the number of entity-hop identities the call expects
      # @return [Routing::Envelope, nil] the resolved envelope, or nil when `to` is nil
      # @raise [Runtime::TypeMismatch] if `to` is malformed or its entity count does not
      #   match `entity_depth`
      def envelope(to, entity_depth: 0) = Invocation.route(to, entity_depth: entity_depth)

      # Resolves a command's offered facts into its flat args hash (see `Invocation.facts_for`).
      #
      # @param command [Class] a `Bluebook::Command` subclass (or port-operation class)
      #   responding to `hecks_name` and `attributes`
      # @param with [Hash, nil] the command's facts, keyed by attribute name; nil when the
      #   caller offers `flat` instead
      # @param flat [Hash] the command's facts as a flat args hash, used when `with` is nil
      # @return [Hash{String, Symbol => Object}] the offered facts by attribute name; an
      #   attribute offered as nil is kept as nil
      # @raise [Runtime::TypeMismatch] if both `with` and a non-empty `flat` are given, if
      #   `with` is not a Hash, or if `with` names an unknown or omits a required attribute
      def payload(command, with:, flat:)
        facts = Invocation.facts_for(command, with: with, flat: flat)
        Invocation.new(verb: nil, target: nil, facts: facts).to_args
      end
    end
  end
end
