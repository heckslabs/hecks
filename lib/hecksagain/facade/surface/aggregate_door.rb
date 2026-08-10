require_relative "../../bluebook/dsl/hecksagon_builder"
require_relative "../../bluebook/dsl/domain_port_builder"
require_relative "../../bluebook/dsl/const_shim"
require_relative "../../bluebook/ir/hexagon"
require_relative "../handle"
require_relative "../../naming"

module Hecksagain
  module Facade
    module Surface
      # One aggregate's door: creating verbs as module methods returning
      # the record in hand, CRUD delegation to the repository, the
      # `persisted_by`-style binding collector a `.hecksagon` lands on, and
      # the aggregate-scoped `port` a `.hecksagon` lands on beside it.
      module AggregateDoor
        def aggregate_module(dispatcher, domain, ir)
          fqn  = "#{domain}::#{ir.hecks_name}"
          door = Module.new

          ir.attributes.each do |attribute|
            next unless RESERVED.include?(attribute.name.to_sym)

            warn "[hecksagain] #{ir.hecks_name}##{attribute.name} shadows a built-in — no reader defined"
          end

          # A creating verb is a MODULE method returning the new record in hand ;
          # a verb that reaches an existing record lives on the Handle.
          ir.commands.select(&:creates?).each do |command|
            door.define_singleton_method(Naming.snake(command.hecks_name)) do |**args|
              Handle.new(dispatcher: dispatcher, domain: domain, ir: ir,
                         instance: dispatcher.dispatch("#{fqn}.#{command.hecks_name}", **args).instance)
            end
          end

          door.define_singleton_method(:fqn)        { fqn }
          door.define_singleton_method(:ir)         { ir }
          door.define_singleton_method(:repository) { dispatcher.registry.repository(domain, ir) }
          door.define_singleton_method(:commands)   { ir.commands.map { |c| Naming.snake(c.hecks_name) }.sort }
          door.define_singleton_method(:count)      { dispatcher.registry.repository(domain, ir).count }
          door.define_singleton_method(:events)     { dispatcher.events.select { |event| event.aggregate == fqn } }

          door.define_singleton_method(:find) do |id|
            found = dispatcher.registry.repository(domain, ir).find(id)
            found && Handle.new(dispatcher: dispatcher, domain: domain, ir: ir, instance: found)
          end

          door.define_singleton_method(:all) do |**opts|
            dispatcher.registry.repository(domain, ir).all(**opts).map do |instance|
              Handle.new(dispatcher: dispatcher, domain: domain, ir: ir, instance: instance)
            end
          end

          # THE SAME REASON `method_missing` BELOW EXISTS AT ALL — a facade
          # left over from a PREVIOUS boot in this process shadows the fresh
          # `BindingProxy` a `.hecksagon` would otherwise reach through
          # `ConstShim`/`const_missing`, so `Pizzas::Pizza.port(...)` lands
          # HERE instead once any boot has run before.
          #
          # RE-RESOLVED, NOT THE CLOSED-OVER `ir` — this door can be a STALE
          # one, built by a boot from earlier in this same process, sitting
          # on the `Pizzas`/`Pizza` constants only because nothing has
          # re-installed them since. Attaching to this door's OWN `ir` would
          # attach the port to a discarded aggregate from that old boot,
          # invisible to the CURRENT one actually being loaded — silently,
          # the exact way `method_missing` below already has to avoid it for
          # a plain bind, via `HecksagonBuilder.collector` rather than
          # anything this door closes over. `Hecksagain.current_registry` is
          # the same "whichever boot is actually in progress" indirection,
          # and `BindingProxy#port` already re-resolves through it the same
          # way — this is that door's fallback twin, not a shortcut past it.
          door.define_singleton_method(:port) do |name, &block|
            current = Hecksagain.current_registry&.bluebook(domain)&.aggregate(ir.hecks_name) or
              raise Bluebook::DSL::Malformed, "#{fqn}.port(#{name.inspect}) called outside a boot"

            domain_port = Bluebook::DSL::ConstShim.with(->(const) { const }) do
              Bluebook::DSL::DomainPortBuilder.build(name, owner: current.hecks_name, &block)
            end
            domain_port.operations.each do |operation|
              operation.attributes.select(&:reference?).each { |attribute| attribute.type.declared_in = current }
            end
            current.add_port(domain_port)
            self
          end

          door.define_singleton_method(:method_missing) do |verb, *args, **kwargs, &block|
            collector = Bluebook::DSL::HecksagonBuilder.collector
            return super(verb, *args, **kwargs, &block) unless collector

            collector << Bluebook::IR::Bind.new(
              aggregate: fqn,
              verb:      verb.to_s,
              adapter:   args.first.to_s,
              role:      kwargs[:role]&.to_s
            )
            block&.call
            self
          end

          door.define_singleton_method(:respond_to_missing?) do |name, include_private = false|
            !Bluebook::DSL::HecksagonBuilder.collector.nil? || super(name, include_private)
          end

          door
        end
      end
    end
  end
end
