require_relative "../../bluebook/dsl/hecksagon_builder"
require_relative "../../bluebook/dsl/domain_port_builder"
require_relative "../../bluebook/dsl/const_shim"
require_relative "../../bluebook/hexagon"
require_relative "../handle"
require_relative "../../naming"

module Hecks
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

            warn "[hecks] #{ir.hecks_name}##{attribute.name} shadows a built-in — no reader defined"
          end

          # A creating verb is a MODULE method returning the new record in hand ;
          # a verb that reaches an existing record lives on the Handle. `!` —
          # a command DOES something (mutates, may refuse), Ruby's own
          # convention for that ; `Naming.snake` alone used to leave a
          # creating command's bare name claiming the exact spelling a
          # QUERY of the SAME business name also wants (`Account`'s own
          # "Open" — the creating command AND a query listing open
          # accounts, a real same-aggregate collision this corpus already
          # has) — the suffix is what makes both nameable at all, not
          # merely a style choice.
          ir.commands.select(&:creates?).each do |command|
            door.define_singleton_method("#{Naming.snake(command.hecks_name)}!") do |**args|
              Handle.new(dispatcher: dispatcher, domain: domain, ir: ir,
                         instance: dispatcher.dispatch("#{fqn}.#{command.hecks_name}", with: args).instance)
            end
          end

          # A query is a MODULE method too — same level as a creating
          # command, since neither needs an existing record in hand — but
          # bare: a query reads and returns, nothing to warn a caller
          # about the way `!` does for a command. Answers the raw row
          # array `dispatcher.query` itself answers, the same shape
          # `runtime.query("#{fqn}.Name")` already gave.
          ir.queries.each do |query|
            door.define_singleton_method(Naming.snake(query.hecks_name)) do |**args|
              dispatcher.query("#{fqn}.#{query.hecks_name}", **args)
            end
          end

          door.define_singleton_method(:fqn)        { fqn }
          door.define_singleton_method(:ir)         { ir }

          # THE SAME VERB THE CHAPTER ANSWERS, one level down. Every
          # construct emits its own IR (Hecks::IR), so an aggregate
          # is a legitimate thing to project — `Pizzas::Order.project(
          # Projections::IR)` is this aggregate's IR, not the chapter's.
          #
          # A chapter-scoped target refuses here rather than inventing an
          # answer: `Projector.admits!` is what tells `Projections::IR`
          # (`from: :any`) apart from `Projections::Shape`
          # (`from: :chapter`), which used to return a confidently empty
          # `{"aggregates" => []}` for an aggregate.
          door.define_singleton_method(:project) do |target, out: nil, **options|
            key      = Projector.key_for(target)
            artifact = Projector.call(key, bluebook: ir, options: options)
            return artifact unless out

            Projector.write(artifact, out, as: Projector.emits_for(key))
          end
          door.define_singleton_method(:repository) { dispatcher.registry.repository(domain, ir) }
          door.define_singleton_method(:commands)   { ir.commands.map { |c| "#{Naming.snake(c.hecks_name)}!" }.sort }
          door.define_singleton_method(:queries)    { ir.queries.map { |q| Naming.snake(q.hecks_name) }.sort }
          # ONE AGGREGATE'S USAGE DOCUMENT — the same projection the chapter
          # answers with, narrowed to this head. `commands` above already
          # answers "what can I call"; this answers "and what does each one
          # want, refuse, and guarantee", which is the rest of the question.
          door.define_singleton_method(:docs) do |**options|
            Projector.call(:docs, bluebook: dispatcher.registry.bluebook(domain),
                                  options:  options.merge(aggregate: ir.hecks_name))
          end
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
          # anything this door closes over. `Hecks.current_registry` is
          # the same "whichever boot is actually in progress" indirection,
          # and `BindingProxy#port` already re-resolves through it the same
          # way — this is that door's fallback twin, not a shortcut past it.
          door.define_singleton_method(:port) do |name, &block|
            current = Hecks.current_registry&.bluebook(domain)&.aggregate(ir.hecks_name) or
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

            collector << Bluebook::Bind.new(
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

          # THE SAME STALE-FACADE HAZARD `method_missing`/`port` ABOVE ALREADY
          # DOCUMENT, one door lower — `Surface.install` installs an aggregate's
          # OWN name as a bare TOP-LEVEL constant too (`Namespace.install(Object,
          # aggregate.hecks_name, ...)`, surface.rb's own `install`), not only
          # nested under its chapter. So once ANY domain has booted once in this
          # process, `Account::Debit` written while declaring some OTHER
          # bluebook — same domain or a different one — reaches THIS door's
          # const_missing directly, never `Object.const_missing`/`ConstShim::
          # Hook` at all: real modules resolve without ever calling that.
          #
          # `ir.hecks_name`, NOT the qualified `fqn` — a scoped reference has to
          # read the SAME either way, whether or not a stale door happens to be
          # sitting on this process from an earlier boot; qualifying it here
          # would make `Account::Debit`'s own meaning depend on incidental
          # process history, which is the exact instability S0b exists to
          # remove (docs/dsl-work-slices.md — "two domains in one registry" is
          # this file's own reason for being owned by that slice).
          door.define_singleton_method(:const_missing) do |name|
            resolver = Bluebook::DSL::ConstShim.resolver
            return resolver.call("#{ir.hecks_name}::#{name}") if resolver

            super(name)
          end

          door
        end
      end
    end
  end
end
