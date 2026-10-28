require_relative "../../framework_bluebooks"
require_relative "ruby/chapter"
require_relative "ruby/aggregate_module"

module Hecks
  module Adapters
    module Driving
      # The Ruby adapter without classes: anonymous per-boot modules whose singleton methods
      # dispatch by FQN, installed by `Loader.bind_runtime` and replaced whole on the next boot.
      #
      # `persisted_by("Heki")` in a `.hecksagon` file lands on the module's `method_missing`,
      # which records a `Bind` into the open `HecksagonBuilder.collector`.
      module Ruby
        # Names that would shadow the machinery a Handle runs on; a field with one gets no reader.
        RESERVED = %i[id state events reload inspect to_h hash class].freeze

        extend Chapter
        extend AggregateModule

        module_function

        # Installs one top-level module per booted bluebook, and one per aggregate, each
        # closing over `dispatcher`, so `Pizzas::Pizza` and the bare `Pizza` both open the
        # module of the boot that ran last.
        #
        # A gem bluebook a hecksagon `attaches` installs nothing (`Query`, `Port` stay free).
        # An aggregate sharing its bluebook's name gets no second constant. A name that user
        # code or the stdlib already owns is left alone with a warning (see `Namespace.install`).
        #
        # @param dispatcher [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] the booted
        #   dispatcher every installed module dispatches and queries through
        # @return [Runtime::Dispatcher, Adapters::Lambda::RemoteDispatcher] the same `dispatcher`
        # @raise [NameError] if a bluebook or aggregate name is not a valid constant name
        def install(dispatcher)
          registry = dispatcher.registry
          Admission.admit!(registry, "Ruby")
          registry.bluebooks.each_value do |bluebook|
            install_chapter(dispatcher, bluebook) unless attached_chapter?(registry, bluebook)
          end
          dispatcher
        end

        # Installs one bluebook's module, and the top-level shortcut of each of its aggregates.
        def install_chapter(dispatcher, bluebook)
          chapter = chapter_module(dispatcher, bluebook)
          Namespace.install(*placement(bluebook), chapter)
          # A namespaced bluebook keeps its aggregates inside its namespace: top-level
          # shortcuts would bring back the collisions the namespace exists to avoid.
          return if bluebook.namespace

          bluebook.aggregates.each do |aggregate|
            next if aggregate.hecks_name == bluebook.name

            Namespace.install(Object, aggregate.hecks_name, chapter.const_get(aggregate.hecks_name, false))
          end
        end

        # Whether `bluebook` is a gem bluebook that a hecksagon attached rather than a domain's own.
        #
        # @param registry [Runtime::Registry] the booted registry
        # @param bluebook [Bluebook::Declaration] the bluebook under test
        # @return [Boolean]
        def attached_chapter?(registry, bluebook)
          registry.bounded?(bluebook.name) && Hecks::FrameworkBluebooks.index.key?(bluebook.name)
        end

        # Where a bluebook's module installs: `Object::<name>`, or the constant path its
        # `namespace` names, creating any missing parent modules along the way.
        #
        # @param bluebook [Bluebook::Declaration] the bluebook being installed
        # @return [Array(Module, String)] the parent module and the constant name within it
        def placement(bluebook)
          return [Object, bluebook.name] unless bluebook.namespace

          *parents, leaf = bluebook.namespace.split("::")
          parent = parents.reduce(Object) do |outer, name|
            outer.const_defined?(name, false) ? outer.const_get(name, false) : outer.const_set(name, Module.new)
          end
          [parent, leaf]
        end
      end
    end
  end
end
