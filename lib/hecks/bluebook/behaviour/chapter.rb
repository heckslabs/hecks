require_relative "traits"

module Hecks
  module Bluebook
    module Behaviour
      # What a chapter does. The declared half is the roll-call of what a
      # bluebook holds; these are the finders over it, plus `verbs`.
      module Chapter
        include Owns

        # Marks this chapter the root of the owner chain, attaches the ports
        # table (filled later by a `.hecksagon`), and stamps ownership.
        #
        # @return [Bluebook::Chapter] self
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

        # What this chapter declared it provides for one capability.
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

        # A port attaches after the chapter already exists, once its
        # hecksagon is built — the same way an aggregate's own ports do.
        #
        # @param port [Bluebook::DomainPort] the operations-shaped port to attach
        # @return [void]
        def add_port(port)
          @ports << port
          @ports_by_name[port.name] = port
        end

        # A translated reaction also attaches after the chapter already
        # exists: which foreign domain's event it reacts to is a wiring
        # decision, not a fact the domain states about its own model.
        #
        # @param policy [Bluebook::Policy] the translated reaction to attach
        # @return [Array<Bluebook::Policy>] this chapter's policies, with `policy` appended
        def add_policy(policy)
          @policies << policy
        end

        # Every dispatchable name this chapter answers to, spelled exactly
        # as `Dispatcher#dispatch` takes it. Derived from the aggregates,
        # never declared, and recurses into entities since a command can be
        # nested arbitrarily deep.
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
