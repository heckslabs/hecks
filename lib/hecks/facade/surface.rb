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
      # An aggregate sharing its chapter's name gets no second constant. A name that user
      # code or the stdlib already owns is left alone with a warning (see `Namespace.install`).
      #
      # @param dispatcher [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted
      #   dispatcher every installed door dispatches and queries through
      # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] the same `dispatcher`
      # @raise [NameError] if a chapter or aggregate name is not a valid constant name
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
