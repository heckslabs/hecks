module Hecks
  module Projections
    module Glossary
      # Gathers every term a chapter's glossary carries, one `Entry` for each, ungrouped and
      # unordered.
      module Entries
        module_function

        # Entities carry their own commands and queries, so they are walked one level down.
        #
        # @param bluebook [Bluebook::Behaviour::Chapter] the chapter
        # @return [Array] every aggregate and entity
        def holders(bluebook)
          bluebook.aggregates.flat_map { |aggregate| [aggregate, *aggregate.entities] }
        end

        # Maps every holder name to its owning aggregate's name.
        def holder_aggregate(bluebook)
          bluebook.aggregates.each_with_object({}) do |aggregate, map|
            map[aggregate.hecks_name] = aggregate.hecks_name
            aggregate.entities.each { |entity| map[entity.hecks_name] = aggregate.hecks_name }
          end
        end

        # Maps each emitted event to its `[holder, command]` raisers. An event is never
        # declared, so its home is the first raiser's aggregate.
        def event_raisers(bluebook)
          holders(bluebook).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |holder, map|
            holder.commands.each { |command| command.emits.each { |event| map[event] << [holder, command] } }
          end
        end

        # The last segment of a dotted name.
        def bare(qualified) = qualified.to_s.split(".").last

        # Gathers every term the glossary carries, ungrouped and unordered.
        #
        # @param bluebook [Bluebook::Behaviour::Chapter] the chapter
        # @param markings [Array<Hash{Symbol => String}>] sensitive fields to tag
        # @return [Array<Glossary::Entry>] every term
        def all(bluebook, markings = [])
          homes = holder_aggregate(bluebook)

          entity_entries(bluebook) + value_object_entries(bluebook, markings) + verb_entries(bluebook, homes) +
            reaction_entries(bluebook, homes) + role_entries(bluebook) + read_model_entries(bluebook)
        end

        # The events, the policies that react to them and the sagas they start, each homed with
        # the aggregate of its event's first raiser.
        def reaction_entries(bluebook, homes)
          raisers = event_raisers(bluebook)
          home_of = ->(event) { raisers.key?(event) ? homes[raisers[event].first.first.hecks_name] : nil }
          event_entries(bluebook, raisers, home_of) + policy_entries(bluebook, home_of) +
            saga_entries(bluebook, home_of)
        end

        def entity_entries(bluebook)
          bluebook.aggregates.flat_map do |aggregate|
            aggregate.entities.map do |entity|
              Entry.new(name: entity.hecks_name, kind: :entity, within: aggregate.hecks_name,
                        section: aggregate.hecks_name, facts: { entity: entity })
            end
          end
        end

        # Aggregates only; `Bluebook::Entity` deliberately does not answer `value_objects`.
        def value_object_entries(bluebook, markings = [])
          bluebook.aggregates.flat_map do |aggregate|
            marked = Sensitivity.for_aggregate(markings, bluebook.name, aggregate)
            aggregate.value_objects.map do |value_object|
              sensitive = Sensitivity.for_value_object(marked, aggregate, value_object)
              Entry.new(name: value_object.hecks_name, kind: :value_object, within: aggregate.hecks_name,
                        section: aggregate.hecks_name,
                        facts: { value_object: value_object, sensitive: sensitive })
            end
          end
        end

        def verb_entries(bluebook, homes)
          holders(bluebook).flat_map { |holder| command_entries(holder, homes) + query_entries(holder, homes) }
        end

        def command_entries(holder, homes)
          holder.commands.map do |command|
            Entry.new(name: command.hecks_name, kind: :command, within: holder.hecks_name,
                      section: homes[holder.hecks_name], facts: { command: command, holder: holder })
          end
        end

        def query_entries(holder, homes)
          holder.queries.map do |query|
            Entry.new(name: query.hecks_name, kind: :query, within: holder.hecks_name,
                      section: homes[holder.hecks_name], facts: { query: query })
          end
        end

        def event_entries(bluebook, raisers, home_of)
          raisers.map do |event, raised_by|
            reactions = bluebook.policies.select { |policy| bare(policy.on_event) == event }
            Entry.new(name: event, kind: :event, section: home_of.call(event),
                      facts: { event: event, raised_by: raised_by, policies: reactions })
          end
        end

        def policy_entries(bluebook, home_of)
          bluebook.policies.map do |policy|
            Entry.new(name: policy.name, kind: :policy, section: home_of.call(bare(policy.on_event)),
                      facts: { policy: policy })
          end
        end

        def saga_entries(bluebook, home_of)
          bluebook.process_managers.map do |saga|
            shape = saga.to_h
            Entry.new(name: shape[:name], kind: :saga, section: home_of.call(bare(shape[:starts_on])),
                      facts: { saga: shape })
          end
        end

        # Roles cut across aggregates, so they get their own section.
        def role_entries(bluebook)
          by_role = Hash.new { |hash, key| hash[key] = [] }
          holders(bluebook).each do |holder|
            holder.commands.select(&:role).each { |command| by_role[command.role] << [holder, command] }
          end
          by_role.map do |role, issues|
            Entry.new(name: role, kind: :role, section: ROLES, facts: { role: role, commands: issues })
          end
        end

        # A read model joins heads from more than one aggregate, so it belongs to none.
        def read_model_entries(bluebook)
          bluebook.read_models.map do |read_model|
            Entry.new(name: read_model.name, kind: :read_model, section: READ_MODELS, facts: { read_model: read_model })
          end
        end
      end
    end
  end
end
