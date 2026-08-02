module Hecksagain
  module Facade
    module Surface
      # One aggregate's door: creating verbs as module methods returning
      # the record in hand, CRUD delegation to the repository, and the
      # `persisted_by`-style binding collector a `.hecksagon` lands on.
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

          door.define_singleton_method(:all) do
            dispatcher.registry.repository(domain, ir).all.map do |instance|
              Handle.new(dispatcher: dispatcher, domain: domain, ir: ir, instance: instance)
            end
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
