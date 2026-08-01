module Hecksagain
  module Facade
    # THE DOOR, WITHOUT THE CLASSES.
    #
    # `Pizzas::Pizza.create_pizza(...)` is the public surface (HANDOVER rule 3),
    # and this is what serves it now : anonymous per-boot modules whose
    # singleton methods close over the dispatcher and dispatch by FQN — the
    # same shape `Router::NamespaceInstaller` proved. Nothing here is a domain
    # class ; the IR is the only graph, and the door is a projection of it,
    # installed by `Loader.bind_runtime` and re-installed whole on the next
    # boot.
    #
    # The hexagon-binding door rides along : `Pizzas::Pizza.persisted_by("Heki")`
    # in a `.hecksagon` file lands on the module's `method_missing`, which
    # records an `IR::Bind` into whatever `HecksagonBuilder.collector` is open
    # AT CALL TIME — so even a facade left over from a previous boot records
    # into the current builder, and a chapter with no constant at all falls
    # through to `ConstShim` → `BindingProxy`, which mints byte-identical binds.
    module Surface
      # These would shadow the machinery a Handle runs on, so a field named one
      # of them gets no reader and says so — the same warning the class door gave.
      RESERVED = %i[id state events reload inspect to_h hash class].freeze

      module_function

      def install(dispatcher)
        dispatcher.registry.bluebooks.each_value do |bluebook|
          chapter = chapter_module(dispatcher, bluebook)
          Namespace.install(Object, bluebook.name, chapter)

          bluebook.aggregates.each do |aggregate|
            next if aggregate.hecks_name == bluebook.name

            Namespace.install(Object, aggregate.hecks_name, chapter.const_get(aggregate.hecks_name, false))
          end
        end
        dispatcher
      end

      def chapter_module(dispatcher, bluebook)
        chapter = Module.new
        chapter.define_singleton_method(:vision)     { bluebook.vision }
        chapter.define_singleton_method(:aggregates) { bluebook.aggregates.map(&:name).sort }

        bluebook.aggregates.each do |aggregate|
          chapter.const_set(aggregate.hecks_name, aggregate_module(dispatcher, bluebook.name, aggregate))
        end

        # INSIDE A HECKSAGON, A NAME IS A DECLARATION, NOT A LOOKUP. A
        # `.hecksagon` may name an aggregate this door does not carry — a STALE
        # door from an earlier boot resolving another registry's chapter, the
        # exact hazard the constant tree used to hide by reinstalling on every
        # load. With a collector open, the name becomes a `BindingProxy`
        # recording the same bind the aggregate module would ; without one, it
        # is a genuine NameError, exactly as before.
        chapter.define_singleton_method(:const_missing) do |name|
          collector = Bluebook::DSL::HecksagonBuilder.collector
          return super(name) unless collector

          Bluebook::DSL::BindingProxy.new("#{bluebook.name}::#{name}", collector)
        end

        chapter
      end

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
