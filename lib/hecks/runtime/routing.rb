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
        # @param aggregate [String, Symbol, #to_s] the receiving aggregate's identity
        # @param entities [Array<String, Symbol>, String, Symbol, nil] the entity chain's own
        #   identities, root-first; nil or a bare value is coerced through `Array()`
        def initialize(aggregate:, entities: [])
          super(aggregate: aggregate.to_s, entities: Array(entities).map(&:to_s).freeze)
          freeze
        end
      end

      module_function

      # Delegates to `Invocation.route` — see that method for the full behavior.
      #
      # @param to [String, Hash, nil] the receiver: an aggregate identity, an entity route
      #   Hash with `:aggregate` and one of `:entity`/`:entities`, or nil
      # @param entity_depth [Integer] the number of entity identities `to` must carry
      # @return [Routing::Envelope, nil] the parsed envelope, or nil when `to` is nil
      # @raise [Runtime::TypeMismatch] if `to` is malformed (see `Invocation.route`)
      def envelope(to, entity_depth: 0) = Invocation.route(to, entity_depth: entity_depth)

      # Loaded by invocation.rb (which requires this file), so `Invocation`
      # is always defined by the time either method runs.
      #
      # @param command [Bluebook::Command, Bluebook::PortOperation] the construct whose
      #   `attributes` the facts are checked against
      # @param with [Hash, nil] the command's facts, keyed by argument name; may not be
      #   combined with a non-empty `legacy`
      # @param legacy [Hash] loose keyword facts, read when `with` is falsy
      # @return [Hash] the offered facts: offered keys in offered order, Absent keys omitted,
      #   Null keys mapped to nil
      # @raise [Runtime::TypeMismatch] if `with:` is combined with a non-empty `legacy`, or
      #   `with:` is not a Hash
      # @raise [Runtime::UnknownArgument] if `with:` offers a key `command` does not declare
      # @raise [Runtime::AbsentArgument] if `with:` omits a non-optional declared attribute
      def payload(command, with:, legacy:)
        facts = Invocation.facts_for(command, with: with, legacy: legacy)
        Invocation.new(verb: nil, target: nil, facts: facts).to_args
      end
    end
  end
end
