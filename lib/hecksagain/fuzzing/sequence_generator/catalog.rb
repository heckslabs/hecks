module Hecksagain
  module Fuzzing
    class SequenceGenerator
      # Everything the booted domain offers, indexed for the picker:
      # creating vs instance commands, entity commands, queries, and the
      # populators that predict where an appended element lands.
      module Catalog
        private

        def build_catalog(runtime)
          creating, instance, entity_commands, queries, entity_queries = [], [], [], [], []

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
              aggregate.entities.each do |entity|
                entity.commands.each do |command|
                  entity_commands << { verb: "#{domain_name}::#{aggregate.hecks_name}.#{entity.hecks_name}.#{command.hecks_name}",
                                       command: command, aggregate: aggregate, entity: entity }
                end
                entity.queries.each do |query|
                  entity_queries << { verb: "#{domain_name}::#{aggregate.hecks_name}.#{entity.hecks_name}.#{query.name}",
                                      query: query, aggregate: aggregate, entity: entity }
                end
              end
            end
          end

          { creating: creating, instance: instance, entity_commands: entity_commands,
            queries: queries, entity_queries: entity_queries, populators: populators(runtime),
            # Which aggregates this corpus can actually make one of — the ones
            # `satisfiable?` is entitled to wait for.
            creatable: creating.map { |entry| entry[:aggregate].hecks_name }.to_set }
        end

        # Which command, on which aggregate, appends to which entity list — so a
        # successful dispatch can predict the identity the element it just added
        # landed on. Entity#identified_by is filled by `Array(current).size + 1`
        # (CommandInterpreter#entity_element) when the append's own field
        # mapping doesn't already assign it — the common case, predicted here.
        # A domain whose append explicitly assigns identity through a mapped
        # argument is covered too, without guessing: whatever value THIS
        # generator supplied for that argument at dispatch time IS the
        # identity, and gets recorded directly (see `record_outcome`).
        def populators(runtime)
          runtime.registry.bluebooks.each_value.flat_map do |bluebook|
            bluebook.aggregates.flat_map do |aggregate|
              aggregate.commands.filter_map do |command|
                append = command.mutations.find { |mutation| mutation.op == :append }
                next unless append

                list_attribute = aggregate.attribute(append.target)
                next unless list_attribute&.list?

                entity = aggregate.entities.find { |candidate| candidate.hecks_name == list_attribute.type.to_s }
                next unless entity

                identity_field = entity.identified_by
                mapped = identity_field && append.source[identity_field]
                { command: command, aggregate: aggregate, entity: entity,
                  identity_field: identity_field, identity_argument: mapped.is_a?(Symbol) ? mapped : nil }
              end
            end
          end
        end
      end
    end
  end
end
