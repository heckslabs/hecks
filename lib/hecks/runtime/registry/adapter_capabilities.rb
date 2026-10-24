module Hecks
  module Runtime
    class Registry
      # Answers what the persistence adapter an aggregate is bound to provides, read from the
      # `provides` lines of its `.adapter` file.
      module AdapterCapabilities
        # Says whether the adapter `aggregate` persists through declares `provides capability`.
        # The bind is the one a repository uses, so a world's `default_adapter` counts.
        #
        # @param domain [String, Symbol] the domain the aggregate belongs to
        # @param aggregate [Bluebook::Aggregate, String] the aggregate, or its declared name
        # @param capability [String, Symbol] the capability, such as `"set_transform"`
        # @return [Boolean] true only when the bound adapter is loaded and provides it
        # @raise [WiringError] if the aggregate's binding is missing or ambiguous
        def adapter_provides?(domain, aggregate, capability)
          bound_adapter(domain, aggregate)&.provides?(capability) || false
        end

        # The loaded adapter declaration `aggregate` persists through.
        #
        # @param domain [String, Symbol] the domain the aggregate belongs to
        # @param aggregate [Bluebook::Aggregate, String] the aggregate, or its declared name
        # @return [Bluebook::Adapter, nil] the bound adapter, or nil when no `.adapter` file
        #   declares the bound name
        # @raise [WiringError] if the aggregate's binding is missing or ambiguous, or the domain
        #   declares no aggregate by that name
        def bound_adapter(domain, aggregate)
          bind = Ports::Persistence::BindingPolicy.resolve(self, domain, aggregate_named(domain, aggregate))
          adapters[bind.adapter]
        end

        private

        def aggregate_named(domain, aggregate)
          return aggregate unless aggregate.is_a?(String) || aggregate.is_a?(Symbol)

          bluebook(domain)&.aggregate(aggregate.to_s) ||
            raise(WiringError, "#{domain} declares no aggregate #{aggregate}")
        end
      end
    end
  end
end
