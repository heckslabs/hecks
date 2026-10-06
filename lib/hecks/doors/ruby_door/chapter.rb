require_relative "../../bluebook/dsl/binding_proxy"
require_relative "../../bluebook/dsl/const_shim"
require_relative "../../bluebook/dsl/hecksagon_builder"

module Hecks
  module Doors
    module RubyDoor
      # One chapter's module: vision and aggregate list on the singleton, one
      # aggregate door per declared head, and a `const_missing` hook for undeclared names.
      module Chapter
        # Builds the anonymous module that stands for one booted chapter: `vision`,
        # `aggregates`, `docs`, `narrate` and `project` as singleton methods, plus one
        # nested constant per aggregate holding that aggregate's door.
        #
        # @param dispatcher [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted
        #   dispatcher each aggregate door closes over
        # @param bluebook [Bluebook::Chapter] the chapter to project into a module
        # @return [Module] a fresh, unnamed module; `RubyDoor.install` gives it its
        #   top-level name
        # @raise [NameError] if an aggregate's name is not a valid constant name
        def chapter_module(dispatcher, bluebook)
          chapter = Module.new
          define_readers(chapter, bluebook)
          define_projections(chapter, bluebook)

          bluebook.aggregates.each do |aggregate|
            chapter.const_set(aggregate.hecks_name, aggregate_module(dispatcher, bluebook.name, aggregate))
          end

          define_const_missing(chapter, bluebook)
          chapter
        end

        private

        # The chapter's vision and its aggregate names.
        def define_readers(chapter, bluebook)
          chapter.define_singleton_method(:vision)     { bluebook.vision }
          chapter.define_singleton_method(:aggregates) { bluebook.aggregates.map(&:name).sort }
        end

        # The chapter's documents and projections, each projected from its IR on every call so
        # none can go stale.
        def define_projections(chapter, bluebook)
          chapter.define_singleton_method(:docs) do |**options|
            Projector.call(:docs, bluebook: bluebook, options: options)
          end

          # The chapter read back in english, via `Projector::NarrateProjector`.
          chapter.define_singleton_method(:narrate) do |**options|
            Projector.call(:narrate, bluebook: bluebook, options: options)
          end

          define_project(chapter, bluebook)
        end

        # Projects the chapter's IR through a target; `out:` writes the artifact and
        # the remaining options go to the projector (`audience:` for OIDC).
        #
        #   Pizzas.project(Projections::OIDC)
        #   Pizzas.project(Projections::Shape, out: "shape.json")
        def define_project(chapter, bluebook)
          chapter.define_singleton_method(:project) do |target, out: nil, **options|
            key      = Projector.key_for(target)
            artifact = Projector.call(key, bluebook: bluebook, options: options)
            return artifact unless out

            Projector.write(artifact, out, as: Projector.emits_for(key))
          end
        end

        # Inside a hecksagon a name is a declaration: with a collector open it becomes
        # a `BindingProxy`. Otherwise a scoped reference from a bluebook mid-declaration
        # goes to the `ConstShim` resolver, so it resolves whether or not a facade exists.
        def define_const_missing(chapter, bluebook)
          chapter.define_singleton_method(:const_missing) do |name|
            collector = Bluebook::DSL::HecksagonBuilder.collector
            return Bluebook::DSL::BindingProxy.new("#{bluebook.name}::#{name}", collector) if collector

            resolver = Bluebook::DSL::ConstShim.resolver
            return resolver.call("#{bluebook.name}::#{name}") if resolver

            super(name)
          end
        end
      end
    end
  end
end
