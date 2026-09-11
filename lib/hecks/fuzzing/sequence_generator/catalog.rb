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

            # THE BARE DOMAIN FORM — "Domain.report_name", no "::" — the
            # SAME shape `Dispatcher#query` itself branches on to route a
            # read-model ask apart from an aggregate query. A report was
            # never in this catalog at all before: `aggregation_matches_
            # recompute` (count/median) has only ever been exercised by
            # hand-built specs, never a single real generated sequence,
            # because nothing here ever asked one. `model:`, not
            # `aggregate:` — a rootless report has no aggregate of its
            # own to be eligible against (see picker.rb's own use of
            # `model.reference_target`).
            bluebook.read_models.each do |model|
              read_models << { verb: "#{domain_name}.#{model.query_name}", model: model }
            end
          end

          { creating: creating, instance: instance, entity_commands: entity_commands,
            queries: queries, entity_queries: entity_queries, read_models: read_models,
            populators: populators(runtime),
            # Which aggregates this corpus can actually make one of — the ones
            # `satisfiable?` is entitled to wait for.
            creatable: creating.to_set { |entry| entry[:aggregate].hecks_name } }
        end

        # EVERY ENTITY, AT EVERY DEPTH — `Card` nested inside `Board`
        # inside `Workspace` (qa/stress_domains/nested_pieces) walks in
        # as `chain: [Board, Card]`, the exact hop list
        # `EntityInterpreter#walk_entity_chain` resolves the dotted verb
        # back into. Before this walk existed the catalog only ever read
        # `aggregate.entities` one level down, so a two-hop entity
        # command (BUG#11's whole class) could never be generated at all
        # — the one shape the differential harness most needed to reach
        # was structurally absent from every sequence it ever produced.
        # `entity:` stays the LAST hop (what every existing reader means
        # by "the entity"); `chain:` is the whole path.
        #
        # Entity QUERIES stay one hop deep, exactly as before — a nested
        # entity's query has no established wire spelling this generator
        # can vouch for, and nothing in the corpus declares one.
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

        # Depth-first, parents before children, in declaration order — so
        # the depth-1 entries land in `entity_commands` in EXACTLY the
        # order they always did (a pinned seed's picker pool is the same
        # pool it was), and a nested entity's own entries follow its
        # parent's.
        def each_entity_chain(owner, chain = [], &block)
          owner.entities.each do |entity|
            path = chain + [entity]
            yield path
            each_entity_chain(entity, path, &block)
          end
        end

        # Which command, on which owner, appends to which entity list — so a
        # successful dispatch can predict the identity the element it just
        # added landed on. Entity#identified_by is filled by `Array(current).size + 1`
        # (CommandInterpreter#entity_element) when the append's own field
        # mapping doesn't already assign it — the common case, predicted here.
        # A domain whose append explicitly assigns identity through a mapped
        # argument is covered too, without guessing: whatever value THIS
        # generator supplied for that argument at dispatch time IS the
        # identity, and gets recorded directly (see `record_outcome`).
        #
        # `owner_chain:` — `[]` for an aggregate-level append (`Board.AddList`,
        # `Folder.AddSlip`), the entity path for an ENTITY-level one
        # (`Board.AddCard` appending into `Board.cards`, owner_chain
        # `[Board]`) — so `record_outcome` can key the appended element
        # under the exact parent-plus-hops it landed beneath.
        # `identity_arguments:` — EVERY identity head the mapping sources
        # from a command argument (a composite entity identity has several),
        # what the adversarial duplicate-identity mutation replays;
        # `identity_argument:` stays the single-head reading the existing
        # auto-mint prediction already keys on.
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
