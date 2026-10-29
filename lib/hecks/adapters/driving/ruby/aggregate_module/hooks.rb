module Hecks
  module Adapters
    module Driving
      module Ruby
        module AggregateModule
          # The hooks an aggregate module lands on: a port declared inside a repeat boot, the bare and
          # qualified binding calls a `.hecksagon` and a `.world` make, and constant lookup. Each is a
          # module function, called as `Hooks.name` from the blocks that define the module's methods, since
          # a block defined with `define_singleton_method` runs with the module as `self`.
          module Hooks
            # What `bound_outcome` answers for a call that is not a binding, so `super` handles it.
            UNBOUND = Object.new.freeze

            # What `bound_outcome` answers for a call that recorded a binding, so the module answers itself.
            BOUND = Object.new.freeze

            module_function

            # Defines `port`, which declares a port on the aggregate during a repeat boot.
            #
            # @param mod [Module] the aggregate module
            # @param domain [String] the domain the aggregate belongs to
            # @param aggregate [Bluebook::Aggregate] the aggregate
            # @param fqn [String] the aggregate's qualified name
            # @return [void]
            def define_port_hook(mod, domain, aggregate, fqn)
              mod.define_singleton_method(:port) do |name, &block|
                Hooks.attach_port(name, domain, aggregate, fqn, &block)
                self
              end
            end

            # Defines `ask_via`, the repeat-boot form of `BindingProxy#ask_via`.
            #
            # @param mod [Module] the aggregate module
            # @param domain [String] the domain the aggregate belongs to
            # @param aggregate [Bluebook::Aggregate] the aggregate
            # @return [void]
            def define_ask_via(mod, domain, aggregate)
              mod.define_singleton_method(:ask_via) do |name, port:|
                declaration = Hecks.current_registry&.bluebook(domain)
                Bluebook::AskResolution.pick!(declaration, aggregate.hecks_name, name, port)
                self
              end
            end

            # Defines `method_missing`: a bare call starts a Privacy marking chain, and a qualified
            # call records a binding. Anything else falls through to `super`.
            #
            # @param mod [Module] the aggregate module
            # @param fqn [String] the aggregate's qualified name
            # @return [void]
            def define_method_missing(mod, fqn)
              mod.define_singleton_method(:method_missing) do |verb, *args, **kwargs, &block|
                outcome = Hooks.bound_outcome(fqn, verb, args, kwargs, block)
                return super(verb, *args, **kwargs, &block) if outcome.equal?(Hooks::UNBOUND)

                outcome.equal?(Hooks::BOUND) ? self : outcome
              end
            end

            # Defines `respond_to_missing?`, answering true while a `.hecksagon` or `.world` is being declared.
            #
            # @param mod [Module] the aggregate module
            # @return [void]
            def define_respond_to_missing(mod)
              mod.define_singleton_method(:respond_to_missing?) do |name, include_private = false|
                !Bluebook::DSL::HecksagonBuilder.collector.nil? || !Bluebook::DSL::WorldBuilder.current.nil? ||
                  super(name, include_private)
              end
            end

            # Defines `const_missing`. It uses `aggregate.hecks_name`, not the qualified name: qualifying it
            # would make `Account::Debit`'s meaning depend on whether a stale module from an earlier boot is
            # still on this process.
            #
            # @param mod [Module] the aggregate module
            # @param aggregate [Bluebook::Aggregate] the aggregate
            # @return [void]
            def define_const_missing(mod, aggregate)
              mod.define_singleton_method(:const_missing) do |name|
                resolver = Bluebook::DSL::ConstShim.resolver
                return resolver.call("#{aggregate.hecks_name}::#{name}") if resolver

                super(name)
              end
            end

            # Declares a port on an aggregate during a repeat boot, and registers it with the live registry.
            # Re-resolves the aggregate via `Hecks.current_registry` rather than the closed-over `aggregate`,
            # which can be stale from an earlier boot.
            #
            # @raise [Bluebook::DSL::Malformed] when called outside a boot
            def attach_port(name, domain, aggregate, fqn, &block)
              current = current_aggregate(name, domain, aggregate, fqn)
              built = Bluebook::DSL::ConstShim.with(->(const) { const }) do
                Bluebook::DSL::DomainPortBuilder.build(name, owner: current.hecks_name, &block)
              end
              # A `verb`-shaped port is a plain `Port`, the same struct `Hecks.port` registers. It belongs to
              # no aggregate IR, so it takes the registry's `add_port` directly. Mirrors `DSL::BindingProxy#port`,
              # which handles the identical shape on a domain's first in-process boot.
              return Hecks.current_registry.add_port(built) if built.is_a?(Bluebook::Port)

              reference_operations(built, current)
              current.add_port(built)
            end

            # @return [Bluebook::Aggregate] the live registry's copy of the aggregate
            # @raise [Bluebook::DSL::Malformed] when no boot is in progress
            def current_aggregate(name, domain, aggregate, fqn)
              Hecks.current_registry&.bluebook(domain)&.aggregate(aggregate.hecks_name) or
                raise Bluebook::DSL::Malformed, "#{fqn}.port(#{name.inspect}) called outside a boot"
            end

            # Points each reference attribute of a port's operations at the aggregate that declares it.
            def reference_operations(built, current)
              built.operations.each do |operation|
                operation.attributes.select(&:reference?).each { |attribute| attribute.type.declared_in = current }
              end
            end

            # Answers what a method-missing call means: a bare call's attribute path, the world's record of
            # a setting, a recorded binding (BOUND), or nothing to bind (UNBOUND).
            #
            # @return [Object] the answer, or BOUND or UNBOUND
            def bound_outcome(fqn, verb, args, kwargs, block)
              return Bluebook::DSL::AttributePath.new(fqn, [verb.to_s]) if bare_call?(args, kwargs, block)

              collector = Bluebook::DSL::HecksagonBuilder.collector
              world = Bluebook::DSL::WorldBuilder.current
              # Inside a `.world` block the same qualified spelling records a world setting.
              return world.record_binding(verb, args, kwargs, block) if world && !collector
              return UNBOUND unless collector

              collector << bind_for(fqn, verb, args, kwargs)
              block&.call
              BOUND
            end

            # @return [Boolean] whether the call names no arguments and no block, so it is a bare attribute path
            def bare_call?(args, kwargs, block)
              args.empty? && kwargs.empty? && !block
            end

            # @return [Bluebook::Bind] the binding a qualified call declares
            def bind_for(fqn, verb, args, kwargs)
              Bluebook::Bind.new(aggregate: fqn, verb: verb.to_s, adapter: args.first.to_s, role: kwargs[:role]&.to_s)
            end
          end
        end
      end
    end
  end
end
