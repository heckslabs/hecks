require_relative "../../bluebook/dsl/binding_proxy"
require_relative "../../bluebook/dsl/hecksagon_builder"

module Hecksagain
  module Facade
    module Surface
      # One chapter's module: vision and aggregate roll-call on the
      # singleton, one aggregate door per declared head, and the
      # declaration hook for names the door does not carry.
      module Chapter
        def chapter_module(dispatcher, bluebook)
          chapter = Module.new
          chapter.define_singleton_method(:vision)     { bluebook.vision }
          chapter.define_singleton_method(:aggregates) { bluebook.aggregates.map(&:name).sort }

          # THE DOMAIN'S OWN IR, PROJECTED. `Projector` has taken
          # `call(name, bluebook:, options:)` since §30, but nothing could
          # reach it from a booted domain — this module already closes
          # over the one `Bluebook` every projector wants and simply
          # never handed it out, so every bin/ projector rebuilt a
          # Registry and reloaded the files to recover what was already
          # sitting here.
          #
          #   Pizzas.project(Projections::OIDC)
          #   Pizzas.project(Projections::Shape, out: "shape.json")
          #
          # No `to_ir` companion: `project(Projections::IR)` already
          # answers with the canonical serialized form, and handing out
          # the live graph as well would be a second way to say the same
          # thing. Anything genuinely needing the graph is a projector,
          # and a projector is given it.
          #
          # `out:` writes and everything else is passed through to the
          # target — so `options` stays the projector's own vocabulary
          # (`audience:` for OIDC) rather than a fixed set this method
          # would have to know about.
          chapter.define_singleton_method(:project) do |target, out: nil, **options|
            artifact = Projector.call(Projector.key_for(target), bluebook: bluebook, options: options)
            out ? Projector.write(artifact, out) : artifact
          end

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
      end
    end
  end
end
