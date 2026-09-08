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

        def resolve(registry, domain, aggregate)
          hexagon = registry.hecksagon(domain)
          return default_binding(aggregate) unless hexagon

          bindings = hexagon.binds_for(aggregate.hecks_name, VERB)
          raise missing_binding(domain, aggregate) if bindings.empty?

          authoritative = bindings.select { |bind| bind.role.nil? || bind.role.empty? }
          raise ambiguous_binding(domain, aggregate, authoritative) unless authoritative.size == 1
          raise unsupported_roles(domain, aggregate, bindings - authoritative) unless (bindings - authoritative).empty?

          authoritative.first
        end

        def default_binding(aggregate)
          Bluebook::Bind.new(aggregate: aggregate.hecks_name, verb: VERB, adapter: DEFAULT_ADAPTER)
        end

        def missing_binding(domain, aggregate)
          Runtime::WiringError.new(
            "#{domain}::#{aggregate.hecks_name} has no #{VERB} bind. #{domain} declares a " \
            "hecksagon, so its wiring is being decided explicitly and an aggregate " \
            "left out is a forgotten decision. Bind it, or say " \
            "#{aggregate.hecks_name}.#{VERB}(#{DEFAULT_ADAPTER.inspect}) to keep it in memory on purpose."
          )
        end

        def ambiguous_binding(domain, aggregate, authoritative)
          Runtime::WiringError.new(
            "#{domain}::#{aggregate.hecks_name} has #{authoritative.size} authoritative #{VERB} bindings. " \
            "Declare exactly one adapter without a role."
          )
        end

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
