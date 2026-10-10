require_relative "../../../bluebook/dsl/hecksagon_builder"
require_relative "../../../bluebook/dsl/world_builder"
require_relative "../../../bluebook/dsl/domain_port_builder"
require_relative "../../../bluebook/dsl/const_shim"
require_relative "../../../bluebook/dsl/binding_proxy"
require_relative "../../../bluebook/hecksagon"
require_relative "../handle"
require_relative "../../../naming"

module Hecks
  module Adapters
    module Driving
      module Ruby
        # One aggregate module: creating verbs and queries as module methods, CRUD
        # delegation, and the `.hecksagon` binding/port hooks it lands on.
        module AggregateModule
          # Builds one aggregate module: creating-command methods, query methods,
          # find/all/count/events, project/docs/narrate, and the port/binding hooks.
          #
          # Kept as one method: `:port`/`:method_missing`/`:const_missing` below
          # cross-reference each other and would lose that thread if split up.
          # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
          def aggregate_module(dispatcher, domain, aggregate)
            fqn = "#{domain}::#{aggregate.hecks_name}"
            mod = Module.new

            aggregate.attributes.each do |attribute|
              next unless RESERVED.include?(attribute.name.to_sym)

              warn "[hecks] #{aggregate.hecks_name}##{attribute.name} shadows a built-in — no reader defined"
            end

            # `!` marks a creating command (Ruby's mutate-and-may-refuse convention).
            # Without it, a query sharing the same business name (e.g. Account's
            # "Open") would collide with the creating command's own bare name.
            aggregate.commands.select(&:creates?).each do |command|
              mod.define_singleton_method("#{Naming.snake(command.hecks_name)}!") do |**args|
                Handle.new(dispatcher: dispatcher, domain: domain, aggregate: aggregate,
                           instance: dispatcher.dispatch("#{fqn}.#{command.hecks_name}", with: args).instance)
              end
            end

            # A query is a bare module method (no `!`): it just reads and returns
            # the same raw row array `dispatcher.query` itself answers.
            aggregate.queries.each do |query|
              mod.define_singleton_method(Naming.snake(query.hecks_name)) do |**args|
                dispatcher.query("#{fqn}.#{query.hecks_name}", **args)
              end
            end

            mod.define_singleton_method(:fqn)        { fqn }
            mod.define_singleton_method(:ir)         { aggregate }

            # Every construct emits its own IR, so an aggregate is a legitimate
            # `project` target too. A chapter-scoped target refuses here via
            # `Projector.admits!` rather than answering a confidently empty result.
            mod.define_singleton_method(:project) do |target, out: nil, **options|
              key      = Projector.key_for(target)
              artifact = Projector.call(key, bluebook: aggregate, options: options)
              return artifact unless out

              Projector.write(artifact, out, as: Projector.emits_for(key))
            end
            mod.define_singleton_method(:repository) { dispatcher.registry.repository(domain, aggregate) }
            mod.define_singleton_method(:commands) do
              aggregate.commands.map { |c| "#{Naming.snake(c.hecks_name)}!" }.sort
            end
            mod.define_singleton_method(:queries) { aggregate.queries.map { |q| Naming.snake(q.hecks_name) }.sort }
            # This chapter's own `:docs` projection, narrowed to this aggregate.
            mod.define_singleton_method(:docs) do |**options|
              Projector.call(:docs, bluebook: dispatcher.registry.bluebook(domain),
                                    options:  options.merge(aggregate: aggregate.hecks_name))
            end
            # Same narrowing as `:docs`, aimed at `:narrate`.
            mod.define_singleton_method(:narrate) do |**options|
              Projector.call(:narrate, bluebook: dispatcher.registry.bluebook(domain),
                                       options:  options.merge(aggregate: aggregate.hecks_name))
            end
            mod.define_singleton_method(:count)      { dispatcher.registry.repository(domain, aggregate).count }
            mod.define_singleton_method(:events)     { dispatcher.events.select { |event| event.aggregate == fqn } }

            mod.define_singleton_method(:find) do |id|
              found = dispatcher.registry.repository(domain, aggregate).find(id)
              found && Handle.new(dispatcher: dispatcher, domain: domain, aggregate: aggregate, instance: found)
            end

            mod.define_singleton_method(:all) do |**opts|
              dispatcher.registry.repository(domain, aggregate).all(**opts).map do |instance|
                Handle.new(dispatcher: dispatcher, domain: domain, aggregate: aggregate, instance: instance)
              end
            end

            # Re-resolves via `Hecks.current_registry` rather than the closed-over
            # `aggregate`: this module can be stale from an earlier boot, and its own
            # `aggregate` would silently port a discarded one instead of the live one.
            mod.define_singleton_method(:port) do |name, &block|
              current = Hecks.current_registry&.bluebook(domain)&.aggregate(aggregate.hecks_name) or
                raise Bluebook::DSL::Malformed, "#{fqn}.port(#{name.inspect}) called outside a boot"

              built = Bluebook::DSL::ConstShim.with(->(const) { const }) do
                Bluebook::DSL::DomainPortBuilder.build(name, owner: current.hecks_name, &block)
              end

              # A `verb`-shaped port is a plain `Port`, the same struct `Hecks.port` registers —
              # it belongs to no aggregate IR the way an operations-shaped `DomainPort` does, so
              # it takes the registry's `add_port` directly. Mirrors `DSL::BindingProxy#port`,
              # which handles the identical shape on a domain's first in-process boot (before
              # this facade constant exists); this method is what a repeat boot reaches instead.
              if built.is_a?(Bluebook::Port)
                Hecks.current_registry.add_port(built)
                return self
              end

              built.operations.each do |operation|
                operation.attributes.select(&:reference?).each { |attribute| attribute.type.declared_in = current }
              end
              current.add_port(built)
              self
            end

            # `BindingProxy#ask_via` for a repeat boot, when this module stands where the proxy is.
            mod.define_singleton_method(:ask_via) do |name, port:|
              chapter = Hecks.current_registry&.bluebook(domain)
              Bluebook::AskResolution.pick!(chapter, aggregate.hecks_name, name, port)
              self
            end

            mod.define_singleton_method(:method_missing) do |verb, *args, **kwargs, &block|
              # A bare call starts a Privacy marking chain (see
              # `BindingProxy#method_missing`), reached here when the module is already
              # installed (a second in-process boot) rather than at parse time.
              return Bluebook::DSL::AttributePath.new(fqn, [verb.to_s]) if args.empty? && kwargs.empty? && !block

              collector = Bluebook::DSL::HecksagonBuilder.collector
              world     = Bluebook::DSL::WorldBuilder.current
              # Inside a `.world` block the same qualified spelling records a world setting.
              return world.record_binding(verb, args, kwargs, block) if world && !collector
              return super(verb, *args, **kwargs, &block) unless collector

              collector << Bluebook::Bind.new(
                aggregate: fqn,
                verb:      verb.to_s,
                adapter:   args.first.to_s,
                role:      kwargs[:role]&.to_s
              )
              block&.call
              self
            end

            mod.define_singleton_method(:respond_to_missing?) do |name, include_private = false|
              !Bluebook::DSL::HecksagonBuilder.collector.nil? || !Bluebook::DSL::WorldBuilder.current.nil? ||
                super(name, include_private)
            end

            # Uses `aggregate.hecks_name`, not the qualified `fqn`: qualifying it here
            # would make `Account::Debit`'s meaning depend on whether a stale module
            # from an earlier boot happens to be sitting on this process.
            mod.define_singleton_method(:const_missing) do |name|
              resolver = Bluebook::DSL::ConstShim.resolver
              return resolver.call("#{aggregate.hecks_name}::#{name}") if resolver

              super(name)
            end

            mod
          end
        end
      end
    end
  end
end
