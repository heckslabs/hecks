require_relative "../errors"
require_relative "../../deprecation"

module Hecks
  module Runtime
    class Registry
      # The names a world gives to what is stored: `stored_as Revision: "commit"` (the table or key
      # an aggregate's rows sit under) at the world's top level, and `formerly "Old"` in a
      # persistence block (the name a domain's history is held under until renamed).
      # These are storage facts, so the world says them and the bluebook does not. The bluebook's
      # `formerly_known_as` still works as a fallback; it warns once, naming the replacement,
      # and must agree with the world when both are given.
      module WorldNames
        PERSISTENCE_VERB = "persisted_by".freeze

        # Applies each domain's world names to its loaded bluebook, then records the names each
        # renamed aggregate's rows may sit under. Safe to call again: the result is the same and
        # the warning is not repeated.
        #
        # @return [Registry] self
        # @raise [WiringError] naming the aggregate or domain when the world and the bluebook
        #   disagree, or `stored_as` names an aggregate the domain does not declare
        def apply_world_names!
          bluebooks.each_value do |bluebook|
            world = world(bluebook.name)
            apply_stored_as!(bluebook, world)
            apply_formerly!(bluebook, world)
            bluebook.aggregates.each { |aggregate| record_prior_names(bluebook, aggregate) }
          end
          self
        end

        private

        def apply_stored_as!(bluebook, world)
          given = world ? world.for_verb("stored_as").except(:adapter) : {}
          given.each { |name, table| adopt_stored_as!(bluebook, name.to_s, table.to_s) }
        end

        def adopt_stored_as!(bluebook, name, table)
          aggregate = bluebook.aggregate(name) ||
                      raise(WiringError, "stored_as names #{name}, but #{bluebook.name} declares no such aggregate")
          former = aggregate.former_name
          if former && Naming.snake(former) != Naming.snake(table)
            raise WiringError, "#{bluebook.name} #{name} is stored_as #{table.inspect} in the world but " \
                               "formerly_known_as #{former.inspect} in the bluebook: they name different tables. " \
                               "Keep the world's line and remove the bluebook's."
          end
          aggregate.stored_as = table
        end

        def apply_formerly!(bluebook, world)
          named = formerly_in(world)
          return unless named

          declared = bluebook.formerly_known_as
          if declared && declared != named
            raise WiringError, "#{bluebook.name} is formerly #{named.inspect} in the world but " \
                               "formerly_known_as #{declared.inspect} in the bluebook: they name different domains. " \
                               "Keep the world's line and remove the bluebook's."
          end
          bluebook.formerly_known_as = named
        end

        def formerly_in(world)
          return nil unless world

          persistence_settings(world).filter_map { |settings| settings[:formerly]&.to_s }.first
        end

        def persistence_settings(world)
          world.settings.select { |key, _| key == PERSISTENCE_VERB || key.start_with?("#{PERSISTENCE_VERB}:") }.values
        end

        def record_prior_names(bluebook, aggregate)
          aggregate.prior_storage_names = [aggregate.former_name, *renamed_from(bluebook, aggregate)].compact.uniq
          warn_formerly_known_as(bluebook, aggregate)
        end

        def renamed_from(bluebook, aggregate)
          edges = translations.select { |edge| edge.domain == bluebook.name }
          edges.filter_map { |edge| edge.for_aggregate(aggregate.name)&.was }
        end

        def warn_formerly_known_as(bluebook, aggregate)
          former = aggregate.former_name
          return unless former

          Deprecation.once([bluebook.name, aggregate.name], deprecation_text(bluebook, aggregate, former))
        end

        def deprecation_text(bluebook, aggregate, former)
          "[hecks] #{bluebook.name} #{aggregate.name}: `formerly_known_as #{former.inspect}` is deprecated. " \
            "Say it in the world: `stored_as #{aggregate.name}: #{Naming.snake(former).inspect}`."
        end
      end
    end
  end
end
