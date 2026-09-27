require_relative "../../bluebook/hexagon"
require_relative "../../runtime/registry"

module Hecks
  module Ports
    module Persistence
      # Resolves one aggregate's persistence topology. An unmarked binding is
      # authoritative; roles are deliberately opt-in so a second adapter can
      # never silently become a read source.
      module BindingPolicy
        module_function

        # Picks the one bind that names an aggregate's authoritative store.
        #
        # A domain with no hecksagon gets the default in-memory bind. A domain that has one
        # must bind the aggregate exactly once without a role.
        #
        # A `default_adapter` a world declares (`Registry#default_adapter_for` — the
        # chapter's own world, else the project's) stands in wherever the hecksagon binds
        # nothing for the aggregate, and replaces the in-memory fallback for a domain
        # with no hecksagon. It is never consulted once the hecksagon binds the aggregate
        # or declares a domain-level default of its own, so an explicit chapter decision
        # always wins.
        #
        # @param registry [Runtime::Registry] the registry holding the domain's hecksagon
        # @param domain [String, Symbol] name of the domain the aggregate belongs to
        # @param aggregate [Bluebook::Aggregate] the aggregate whose binding is wanted
        # @return [Bluebook::Bind] the authoritative `persisted_by` bind, or the default
        #   `Memory` bind when the domain declares no hecksagon
        # @raise [Runtime::WiringError] if the hecksagon has no `persisted_by` bind for the
        #   aggregate, more or fewer than one bind without a role, or any bind with a role
        def resolve(registry, domain, aggregate)
          hexagon  = registry.hecksagon(domain)
          declared = registry.default_adapter_for(domain)
          return default_binding(aggregate, declared || DEFAULT_ADAPTER) unless hexagon

          bindings = hexagon.binds_for(aggregate.hecks_name, VERB)
          bindings = [default_binding(aggregate, declared)] if bindings.empty? && declared
          raise missing_binding(domain, aggregate) if bindings.empty?

          authoritative = bindings.select { |bind| bind.role.nil? || bind.role.empty? }
          raise ambiguous_binding(domain, aggregate, authoritative) unless authoritative.size == 1
          raise unsupported_roles(domain, aggregate, bindings - authoritative) unless (bindings - authoritative).empty?

          authoritative.first
        end

        # Builds the bind an aggregate gets when its domain declares no hecksagon.
        #
        # @param aggregate [Bluebook::Aggregate] the aggregate to bind
        # @param adapter [String] the adapter to bind it to; the framework's in-memory
        #   default unless a world declared one
        # @return [Bluebook::Bind] a roleless `persisted_by` bind to `adapter`
        def default_binding(aggregate, adapter = DEFAULT_ADAPTER)
          Bluebook::Bind.new(aggregate: aggregate.hecks_name, verb: VERB, adapter: adapter)
        end

        # Builds, without raising, the error for an aggregate a hecksagon leaves unbound.
        #
        # @param domain [String, Symbol] name of the domain, used in the message
        # @param aggregate [Bluebook::Aggregate] the aggregate with no bind
        # @return [Runtime::WiringError] an error whose message says how to bind the aggregate
        def missing_binding(domain, aggregate)
          Runtime::WiringError.new(
            "#{domain}::#{aggregate.hecks_name} has no #{VERB} bind. #{domain} declares a " \
            "hecksagon, so its wiring is being decided explicitly and an aggregate " \
            "left out is a forgotten decision. Bind it, or say " \
            "#{aggregate.hecks_name}.#{VERB}(#{DEFAULT_ADAPTER.inspect}) to keep it in memory on purpose."
          )
        end

        # Builds, without raising, the error for an aggregate whose count of roleless binds
        # is not one.
        #
        # @param domain [String, Symbol] name of the domain, used in the message
        # @param aggregate [Bluebook::Aggregate] the aggregate with the wrong bind count
        # @param authoritative [Array<Bluebook::Bind>] the roleless binds found; may be empty
        # @return [Runtime::WiringError] an error whose message reports the count
        def ambiguous_binding(domain, aggregate, authoritative)
          Runtime::WiringError.new(
            "#{domain}::#{aggregate.hecks_name} has #{authoritative.size} authoritative #{VERB} bindings. " \
            "Declare exactly one adapter without a role."
          )
        end

        # Builds, without raising, the error for binds that carry a role this port ignores.
        #
        # @param domain [String, Symbol] name of the domain, used in the message
        # @param aggregate [Bluebook::Aggregate] the aggregate carrying the binds
        # @param bindings [Array<Bluebook::Bind>] the binds that declare a role
        # @return [Runtime::WiringError] an error whose message lists each role
        def unsupported_roles(domain, aggregate, bindings)
          Runtime::WiringError.new(
            "#{domain}::#{aggregate.hecks_name} uses persistence role#{'s' unless bindings.size == 1} " \
            "#{bindings.map(&:role).map(&:inspect).join(', ')}. Only persisted_by is supported."
          )
        end
      end
    end
  end
end
