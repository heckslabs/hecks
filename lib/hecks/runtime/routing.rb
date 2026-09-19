module Hecks
  module Runtime
    # The invocation address is not part of a command's domain payload.
    # Aggregate commands carry one receiver identity; entity commands carry
    # the aggregate receiver followed by one identity for every entity hop.
    #
    # Reading a call's shape — what `to:` and `with:` mean, the BUG#7/#17/#18
    # rules — lives in `Runtime::Invocation.from_call` now (invocation.rb).
    # `envelope`/`payload` are kept as thin delegators for any caller still
    # naming them; the dispatcher itself builds an Invocation instead.
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

      # Resolves a `to:` argument into a routing envelope. A thin delegator to
      # `Invocation.route`; the dispatcher itself builds an `Invocation` instead.
      #
      # @param to [String, Hash, nil] a bare aggregate identity, or a Hash with
      #   `aggregate:` and `entity:`/`entities:`; nil for no receiver
      # @param entity_depth [Integer] the number of entity-hop identities the call expects
      # @return [Routing::Envelope, nil] the resolved envelope, or nil when `to` is nil
      # @raise [Runtime::TypeMismatch] if `to` is malformed or its entity count does not
      #   match `entity_depth`
      def envelope(to, entity_depth: 0) = Invocation.route(to, entity_depth: entity_depth)

      # Resolves a command's offered facts into its flat args hash. A thin
      # delegator to `Invocation.facts_for` for any caller still naming it.
      #
      # Loaded by invocation.rb (which requires this file), so `Invocation`
      # is always defined by the time either method runs.
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
