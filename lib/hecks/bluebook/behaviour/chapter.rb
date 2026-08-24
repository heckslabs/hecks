require_relative "traits"

module Hecks
  module Bluebook
    module Behaviour
      # WHAT A CHAPTER DOES. The declared half is the roll-call of what a
      # bluebook holds; these are the finders over it, plus `verbs` — the
      # chapter's own list of every dispatchable name, which is derived
      # from the aggregates rather than declared anywhere.
      module Chapter
        include Owns

        # THE HOOK THE GENERATED CONSTRUCTOR CALLS. Three things a
        # declaration does not state: that a chapter is the ROOT of the
        # owner chain (nothing declares it, it is what having no owner
        # MEANS), the ports table — which a `.hecksagon` fills later, so
        # the bluebook cannot declare it — and stamping its own children,
        # the same act an Aggregate performs one level down.
        def settle
          @hecks_root    = true
          @ports         = []
          @ports_by_name = {}
          stamp(@aggregates, @read_models)
          self
        end

        def aggregate(named)  = @aggregates.find { |a| a.name == named.to_s }
        def read_model(named) = @read_models.find { |model| model.name == named.to_s || model.query_name == named.to_s }
        def port(named)       = @ports_by_name[named.to_s]

        # A PORT IS DECLARED IN THE HECKSAGON, not the bluebook — so it
        # attaches after the chapter already exists, the same way an
        # aggregate's own ports do.
        def add_port(port)
          @ports << port
          @ports_by_name[port.name] = port
        end

        # Every dispatchable name this chapter answers to, spelled exactly
        # as Dispatcher#dispatch takes it. Derived from the aggregates,
        # never declared — which is why Projections::OIDC can hold its own
        # scope list equal to this and have that mean something.
        #
        # Recurses into entities, not just an aggregate's own direct
        # commands — `Dispatcher#dispatch` already routes a dotted
        # `Domain::Aggregate.Entity.Command` verb to `EntityInterpreter`
        # (a command_name with a "." in it), so a verb this method left
        # out was never "not a verb," only one this list forgot to name.
        # Ported from the same recursive shape `spec/judge_coverage_spec.rb`
        # already proved out for the meta-domain's own grammar (S17, ADR
        # 0026) — entities nest arbitrarily deep (`Dispatch`, inside
        # `Handler`), so one flat level isn't enough.
        def verbs
          @aggregates.flat_map { |agg| aggregate_verbs(agg) }
        end

        private

        def aggregate_verbs(agg)
          agg.commands.map { |cmd| "#{@name}::#{agg.hecks_name}.#{cmd.hecks_name}" } +
            agg.entities.flat_map { |entity| entity_verbs("#{@name}::#{agg.hecks_name}", entity) }
        end

        def entity_verbs(prefix, entity)
          dotted = "#{prefix}.#{entity.hecks_name}"
          entity.commands.map { |cmd| "#{dotted}.#{cmd.hecks_name}" } +
            entity.entities.flat_map { |piece| entity_verbs(dotted, piece) }
        end
      end
    end
  end
end
