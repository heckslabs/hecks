require_relative "../../bluebook/hecksagon"
require_relative "../../runtime/registry"

module Hecks
  module Ports
    module Persistence
      # Resolves one aggregate's persistence topology; an unmarked binding is
      # authoritative, and roles are opt-in so no adapter silently becomes a read source.
      module BindingPolicy
        module_function

        # Picks the one bind that names an aggregate's authoritative store: its own bind, its
        # chapter's root default, an attaching domain's root default, a world's `default_adapter`,
        # then Memory. A hecksagon that binds some aggregates and leaves this one out is refused
        # as a forgotten decision; one that never mentions persistence has made none.
        #
        # @param registry [Runtime::Registry] the registry holding the domain's hecksagon
        # @param domain [String, Symbol] name of the domain the aggregate belongs to
        # @param aggregate [Bluebook::Aggregate] the aggregate whose binding is wanted
        # @return [Bluebook::Bind] the authoritative `persisted_by` bind
        # @raise [Runtime::WiringError] if some aggregates are bound and this one is not, the roleless
        #   binds are not exactly one, a bind has a role, or attaching domains disagree
        def resolve(registry, domain, aggregate)
          hecksagon = registry.hecksagon(domain)
          declared  = registry.default_adapter_for(domain)
          return default_binding(aggregate, declared || DEFAULT_ADAPTER) unless hecksagon

          bindings = declared_bindings(registry, domain, hecksagon, aggregate, declared)
          return default_binding(aggregate) if bindings.empty? && !wired?(hecksagon)
          raise missing_binding(domain, aggregate) if bindings.empty?

          authoritative_among(bindings, domain, aggregate)
        end

        # Whether a hecksagon has made a persistence decision: it binds some aggregate, or the
        # domain, to an adapter other than the default. A bind to Memory decides nothing the
        # default had not, so it does not count.
        #
        # @param hecksagon [Bluebook::Hexagon] the domain's hecksagon
        # @return [Boolean]
        def wired?(hecksagon)
          hecksagon.binds.any? { |bind| bind.verb.to_s == VERB && bind.adapter.to_s != DEFAULT_ADAPTER }
        end

        # Whether a domain's hecksagon leaves persistence entirely unwired: no bind of its own, no
        # default handed down by an attaching domain, and no world default.
        #
        # @param registry [Runtime::Registry] the registry holding the domain's hecksagon
        # @param domain [String, Symbol] name of the domain
        # @return [Boolean] false when the domain declares no hecksagon at all
        def unwired?(registry, domain)
          hecksagon = registry.hecksagon(domain)
          return false unless hecksagon

          !wired?(hecksagon) && registry.default_adapter_for(domain).nil? && inherited_adapter(registry, domain).nil?
        end

        # The adapter the root default of an attaching domain hands to a chapter it attaches, so one
        # `persisted_by` at a domain's root reaches the chapters it brings in.
        #
        # @param registry [Runtime::Registry] the registry holding every hecksagon
        # @param domain [String, Symbol] name of the attached chapter
        # @return [String, nil] the adapter, nil when no attaching domain declares a default
        # @raise [Runtime::WiringError] if two attaching domains declare different defaults
        def inherited_adapter(registry, domain)
          attachers = registry.hecksagons.values.select { |hecksagon| hecksagon.attaches?(domain) }
          adapters  = attachers.flat_map { |hecksagon| hecksagon.default_binds(VERB) }.map(&:adapter).uniq
          raise conflicting_defaults(domain, adapters) if adapters.size > 1

          adapters.first
        end

        # Picks the single roleless bind, refusing any other count and any bind with a role.
        #
        # @param bindings [Array<Bluebook::Bind>] the aggregate's binds; not empty
        # @param domain [String, Symbol] name of the domain, used in refusal messages
        # @param aggregate [Bluebook::Aggregate] the aggregate the binds belong to
        # @return [Bluebook::Bind] the authoritative bind
        # @raise [Runtime::WiringError] if the roleless count is not one, or a role is present
        def authoritative_among(bindings, domain, aggregate)
          authoritative = bindings.select { |bind| bind.role.nil? || bind.role.empty? }
          raise ambiguous_binding(domain, aggregate, authoritative) unless authoritative.size == 1

          roled = bindings - authoritative
          raise unsupported_roles(domain, aggregate, roled) unless roled.empty?

          authoritative.first
        end

        # Lists the hecksagon's `persisted_by` binds for an aggregate, or else the bind an attaching
        # domain's root default or the world's default adapter gives it.
        #
        # @param registry [Runtime::Registry] the registry holding every hecksagon
        # @param domain [String, Symbol] name of the aggregate's domain
        # @param hecksagon [Bluebook::Hexagon] the domain's hecksagon
        # @param aggregate [Bluebook::Aggregate] the aggregate whose binds are wanted
        # @param declared [String, nil] the world's default adapter, if any
        # @return [Array<Bluebook::Bind>] the binds; empty when none and no default exists
        def declared_bindings(registry, domain, hecksagon, aggregate, declared)
          bindings = hecksagon.binds_for(aggregate.hecks_name, VERB)
          return bindings unless bindings.empty?

          fallback = inherited_adapter(registry, domain) || declared
          fallback ? [default_binding(aggregate, fallback)] : []
        end

        # Builds, without raising, the error for attaching domains that declare different defaults.
        #
        # @param domain [String, Symbol] name of the attached chapter
        # @param adapters [Array<String>] the differing defaults
        # @return [Runtime::WiringError] an error whose message names the adapters
        def conflicting_defaults(domain, adapters)
          Runtime::WiringError.new(
            "#{domain} is attached by domains that bind #{VERB} by default to different adapters " \
            "(#{adapters.join(", ")}). Bind #{domain} itself, or make the attaching domains agree."
          )
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
            "#{domain}::#{aggregate.hecks_name} uses persistence role#{"s" unless bindings.size == 1} " \
            "#{bindings.map { |binding| binding.role.inspect }.join(", ")}. Only persisted_by is supported."
          )
        end
      end
    end
  end
end
