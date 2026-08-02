require_relative "surface/chapter"
require_relative "surface/aggregate_door"

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
    # boot. How a chapter's module is built is surface/chapter.rb; how one
    # aggregate's door is built is surface/aggregate_door.rb.
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

      extend Chapter
      extend AggregateDoor

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
    end
  end
end
