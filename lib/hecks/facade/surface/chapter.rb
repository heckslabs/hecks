require_relative "../../bluebook/dsl/binding_proxy"
require_relative "../../bluebook/dsl/const_shim"
require_relative "../../bluebook/dsl/hecksagon_builder"

module Hecks
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

          # THE CHAPTER, EXPLAINING ITSELF. `Projector::DocsProjector` reads
          # nothing but this bluebook's own IR, so the document cannot drift
          # from the domain — the same guarantee `bin/reference` gives the DSL
          # reference by generating it from the Syntax chapter.
          #
          # A METHOD RATHER THAN ONLY A SCRIPT because that is what gets it
          # read: `QualityControl.docs` in a console, beside `vision` and
          # `aggregates`, at the moment somebody is wondering what a verb
          # wants. Projected on each call rather than memoised — it is a pure
          # read of the IR, and a stale document is the entire thing this
          # exists to prevent.
          chapter.define_singleton_method(:docs) do |**options|
            Projector.call(:docs, bluebook: bluebook, options: options)
          end

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
            key      = Projector.key_for(target)
            artifact = Projector.call(key, bluebook: bluebook, options: options)
            return artifact unless out

            Projector.write(artifact, out, as: Projector.emits_for(key))
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
          #
          # THE OTHER READER OF A MISS is S0b's own bridge (docs/dsl-work-
          # slices.md, const_shim.rb's `ScopedConstant`): a bluebook still being
          # DECLARED that names `#{bluebook.name}::Something` — an event, a
          # command reference, an `admits:` — reaches HERE, not
          # `Object.const_missing`, the moment this chapter's own facade already
          # exists (a previous boot in the same process, or this same chapter
          # re-entering its own name). `ConstShim.active?` is exactly as true
          # here as it is at the top level, mid-declaration, and consulting the
          # SAME resolver is what makes a scoped reference resolve identically
          # whether or not a facade happens to be built yet — the earlier
          # attempt's own failure mode (this file's own history) was a bridge
          # that worked only BEFORE any facade existed.
          chapter.define_singleton_method(:const_missing) do |name|
            collector = Bluebook::DSL::HecksagonBuilder.collector
            return Bluebook::DSL::BindingProxy.new("#{bluebook.name}::#{name}", collector) if collector

            resolver = Bluebook::DSL::ConstShim.resolver
            return resolver.call("#{bluebook.name}::#{name}") if resolver

            super(name)
          end

          chapter
        end
      end
    end
  end
end
