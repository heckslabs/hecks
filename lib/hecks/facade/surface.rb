require_relative "../chapters"
require_relative "surface/chapter"
require_relative "surface/aggregate_door"

module Hecks
  module Facade
    # The door without classes: anonymous per-boot modules whose singleton methods
    # dispatch by FQN, installed by `Loader.bind_runtime` and replaced whole on the next boot.
    #
    # `persisted_by("Heki")` in a `.hecksagon` file lands on the module's `method_missing`,
    # which records a `Bind` into the open `HecksagonBuilder.collector`.
    module Surface
      # Names that would shadow the machinery a Handle runs on; a field with one gets no reader.
      RESERVED = %i[id state events reload inspect to_h hash class].freeze

      extend Chapter
      extend AggregateDoor

      module_function

      # Installs one top-level module per booted chapter, and one per aggregate, each
      # closing over `dispatcher`, so `Pizzas::Pizza` and the bare `Pizza` both open the
      # door of the boot that ran last.
      #
      # A gem chapter a hecksagon `attaches` installs nothing (`Query`, `Port` stay free).
      # An aggregate sharing its chapter's name gets no second constant. A name that user
      # code or the stdlib already owns is left alone with a warning (see `Namespace.install`).
      #
      # @param dispatcher [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted
      #   dispatcher every installed door dispatches and queries through
      # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] the same `dispatcher`
      # @raise [NameError] if a chapter or aggregate name is not a valid constant name
      def install(dispatcher)
        dispatcher.registry.bluebooks.each_value do |bluebook|
          next if attached_chapter?(dispatcher.registry, bluebook)

          chapter = chapter_module(dispatcher, bluebook)
          Namespace.install(*placement(bluebook), chapter)
          # A namespaced chapter keeps its aggregates inside its namespace: top-level
          # shortcuts would bring back the collisions the namespace exists to avoid.
          next if bluebook.namespace

          bluebook.aggregates.each do |aggregate|
            next if aggregate.hecks_name == bluebook.name

            Namespace.install(Object, aggregate.hecks_name, chapter.const_get(aggregate.hecks_name, false))
          end
        end
        dispatcher
      end

      # Whether `bluebook` is a gem chapter that a hecksagon attached rather than a domain's own.
      #
      # @param registry [Runtime::Registry] the booted registry
      # @param bluebook [Bluebook::Chapter] the chapter under test
      # @return [Boolean]
      def attached_chapter?(registry, bluebook)
        registry.bounded?(bluebook.name) && Hecks::Chapters.index.key?(bluebook.name)
      end

      # Where a chapter's module installs: `Object::<name>`, or the constant path its
      # `namespace` names, creating any missing parent modules along the way.
      #
      # @param bluebook [Bluebook::Chapter] the chapter being installed
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
