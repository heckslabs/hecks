module Hecks
  module Fuzzing
    class SequenceGenerator
      # Everything the booted domain offers, indexed for the picker:
      # creating vs instance commands, entity commands, queries, and the
      # populators that predict where an appended element lands.
      module Catalog
        private

        def build_catalog(runtime)
          creating = []
          instance = []
          entity_commands = []
          queries = []
          entity_queries = []
          read_models = []

          runtime.registry.bluebooks.each do |domain_name, bluebook|
            bluebook.aggregates.each do |aggregate|
              aggregate.commands.each do |command|
                entry = { verb: "#{domain_name}::#{aggregate.hecks_name}.#{command.hecks_name}",
                          command: command, aggregate: aggregate }
                (command.creates? ? creating : instance) << entry
              end
              aggregate.queries.each do |query|
                queries << { verb: "#{domain_name}::#{aggregate.hecks_name}.#{query.name}",
                             query: query, aggregate: aggregate }
              end
              catalog_entities(domain_name, aggregate, entity_commands, entity_queries)
            end

            # Reports use the bare "Domain.report_name" form, which `Dispatcher#query`
            # routes to the read model. Keyed by `model:`, not `aggregate:`: a
            # rootless report has no aggregate to be eligible against.
            bluebook.read_models.each do |model|
              read_models << { verb: "#{domain_name}.#{model.query_name}", model: model }
            end
          end

          { creating: creating, instance: instance, entity_commands: entity_commands,
            queries: queries, entity_queries: entity_queries, read_models: read_models,
            populators: populators(runtime),
            # The aggregates a query filters on, and the fields it compares.
            query_bindings: build_query_bindings(runtime),
            # Every `role "..."` a command declares; the `mismatched` caller shape draws from it.
            roles: (creating + instance + entity_commands).filter_map { |e| e[:command].role }
                                                          .map(&:to_s).reject(&:empty?).uniq.sort,
            # The grant verb each authorization provider declares, read off the
            # declaration rather than a hard-coded Governance name.
            grant_verbs: runtime.registry.authorization_providers
                                .filter_map { |chapter| chapter.provided_verb(Bluebook::Capabilities::AUTHORIZATION, :grant) }
                                .sort,
            # Aggregates some creating command can make; `satisfiable?` only waits on these.
            creatable: creating.to_set { |entry| entry[:aggregate].hecks_name } }
        end

        # Indexes every entity at every depth; `chain:` is the whole hop list
        # (`[Board, Card]`) and `entity:` its last hop.
        #
        # Entity queries stay one hop deep: a nested entity's query has no
        # established wire spelling.
        def catalog_entities(domain_name, aggregate, entity_commands, entity_queries)
          each_entity_chain(aggregate) do |chain|
            entity = chain.last
            path   = chain.map(&:hecks_name).join(".")
            entity.commands.each do |command|
              entity_commands << { verb: "#{domain_name}::#{aggregate.hecks_name}.#{path}.#{command.hecks_name}",
                                   command: command, aggregate: aggregate, entity: entity, chain: chain }
            end
            next unless chain.size == 1

            entity.queries.each do |query|
              entity_queries << { verb: "#{domain_name}::#{aggregate.hecks_name}.#{path}.#{query.name}",
                                  query: query, aggregate: aggregate, entity: entity }
            end
          end
        end

        # Depth-first, parents before children, in declaration order, which
        # keeps a pinned seed's picker pool stable.
        def each_entity_chain(owner, chain = [], &block)
          owner.entities.each do |entity|
            path = chain + [entity]
            yield path
            each_entity_chain(entity, path, &block)
          end
        end

        # Which command appends to which entity list, so a successful dispatch
        # can predict the identity of the element it added.
        #
        # `owner_chain:` is `[]` for an aggregate-level append and the entity
        # path for an entity-level one. `identity_arguments:` lists every
        # identity head sourced from a command argument; `identity_argument:`
        # is the single-head reading the auto-mint prediction keys on.
        def populators(runtime)
          runtime.registry.bluebooks.each_value.flat_map do |bluebook|
            bluebook.aggregates.flat_map do |aggregate|
              owners = [[aggregate, []]]
              each_entity_chain(aggregate) { |chain| owners << [chain.last, chain] }

              owners.flat_map do |owner, chain|
                owner.commands.filter_map { |command| populator_for(aggregate, owner, chain, command) }
              end
            end
          end
        end

        def populator_for(aggregate, owner, chain, command)
          append = command.mutations.find { |mutation| mutation.op == :append }
          return unless append

          list_attribute = owner.attribute(append.target)
          return unless list_attribute&.list?

          entity = owner.entities.find { |candidate| candidate.hecks_name == list_attribute.type.to_s }
          return unless entity

          identity_field = entity.identified_by
          mapped = identity_field && append.source[identity_field]
          identity_arguments = entity.identity_heads.filter_map do |head|
            source = append.source[head]
            source if source.is_a?(Symbol)
          end
          { command: command, aggregate: aggregate, owner: owner, owner_chain: chain, entity: entity,
            identity_field: identity_field, identity_argument: mapped.is_a?(Symbol) ? mapped : nil,
            identity_arguments: identity_arguments }
        end
      end
    end
  end
end
