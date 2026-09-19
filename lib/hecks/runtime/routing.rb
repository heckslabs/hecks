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
        def initialize(aggregate:, entities: [])
          super(aggregate: aggregate.to_s, entities: Array(entities).map(&:to_s).freeze)
          freeze
        end
      end

      module_function

      def envelope(to, entity_depth: 0) = Invocation.route(to, entity_depth: entity_depth)

      # Loaded by invocation.rb (which requires this file), so `Invocation`
      # is always defined by the time either method runs.
      def payload(command, with:, flat:)
        facts = Invocation.facts_for(command, with: with, flat: flat)
        Invocation.new(verb: nil, target: nil, facts: facts).to_args
      end
    end
  end
end
