require_relative "traits"

module Hecks
  module Bluebook
    module Behaviour
      # **What a chapter does**. The declared half is the roll-call of what a
      # bluebook holds; these are the finders over it, plus `verbs` — the
      # chapter's own list of every dispatchable name, which is derived
      # from the aggregates rather than declared anywhere.
      module Chapter
        include Owns

        # The hook the generated constructor calls. Three things a
        # declaration does not state: that a chapter is the root of the
        # owner chain (nothing declares it, it is what having no owner
        # means), the ports table — which a `.hecksagon` fills later, so
        # the bluebook cannot declare it — and stamping its own children,
        # the same act an Aggregate performs one level down.
        #
        # @return [Bluebook::Chapter] self, once root marking, the ports table and ownership
        #   stamping are all set up
        def settle
          @hecks_root    = true
          @ports         = []
          @ports_by_name = {}
          stamp(@aggregates, @read_models)
          self
        end

        # Finds a declared aggregate by name.
        #
        # @param named [String, Symbol] the aggregate's declared name
        # @return [Bluebook::Aggregate, nil] the aggregate, or `nil` if none is declared
        #   by that name
        def aggregate(named)  = @aggregates.find { |a| a.name == named.to_s }

        # Finds a declared read model by its own name or by the query name it answers.
        #
        # @param named [String, Symbol] the read model's declared name, or its query name
        # @return [Bluebook::ReadModel, nil] the read model, or `nil` if none matches
        def read_model(named) = @read_models.find { |model| model.name == named.to_s || model.query_name == named.to_s }

        # Finds a port declared at this chapter's root by name.
        #
        # @param named [String, Symbol] the port's declared name
        # @return [Bluebook::DomainPort, nil] the port, or `nil` if none is declared
        #   by that name
        def port(named)       = @ports_by_name[named.to_s]

        # What this chapter declared it provides — `{ key => local verb }`
        # for one capability, or nil when it declares none. Read by
        # everything that resolves a capability's provider from what a
        # chapter declares, rather than from the chapter's own name
        # (`Registry#authorization_provider_for`).
        #
        # @param capability [String, Symbol] the capability's name, such as
        #   `Bluebook::Capabilities::AUTHORIZATION`
        # @return [Hash{Symbol => String}, nil] each declared key mapped to its local verb,
        #   or `nil` if this chapter declares no `provides` row for that capability
        def provision(capability)
          rows = @provides.select { |row| row.capability == capability.to_s }
          rows.empty? ? nil : rows.to_h { |row| [row.key.to_sym, row.verb] }
        end

        # Says whether this chapter declares that it provides a capability.
        #
        # @param capability [String, Symbol] the capability's name
        # @return [Boolean] whether this chapter declares a `provides` row for that capability
        def provides?(capability) = !provision(capability).nil?

        # The declared verb for `key`, qualified with this chapter's own
        # name — the spelling `Dispatcher#dispatch`/`#query` take.
        #
        # @param capability [String, Symbol] the capability's name
        # @param key [String, Symbol] the provided key to resolve
        # @return [String, nil] the verb qualified as `"ChapterName::verb"`, or `nil` if this
        #   chapter provides no such capability or key
        def provided_verb(capability, key)
          local = provision(capability)&.fetch(key.to_sym, nil)
          local && "#{name}::#{local}"
        end

        # A port is declared in the hecksagon, not the bluebook — so it
        # attaches after the chapter already exists, the same way an
        # aggregate's own ports do.
        #
        # @param port [Bluebook::DomainPort] the operations-shaped port to attach
        # @return [void]
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
        #
        # @return [Array<String>] every command verb reachable on this chapter, spelled
        #   `"Domain::Aggregate.command"` or, nested, `"Domain::Aggregate.Entity.command"`
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
