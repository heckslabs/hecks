require_relative "../value_generator"

module Hecks
  module Fuzzing
    class SequenceGenerator
      # What a successful step created, and how a later step draws on it —
      # the state tracking that makes multi-step sequences reach further
      # than single calls ever did.
      module OutcomeTracker
        private

        def record_outcome(catalog, entry, args)
          aggregate = entry[:aggregate]
          parent_key = (aggregate.identified_by || :id).to_s
          parent_scalar = ValueGenerator.scalar_of(args[parent_key])

          @known_ids[aggregate.hecks_name] << parent_scalar if entry[:entity].nil? && entry[:command].creates?

          populator = catalog[:populators].find { |p| p[:command].equal?(entry[:command]) && p[:aggregate].equal?(aggregate) }
          return unless populator

          key = "#{aggregate.hecks_name}.#{populator[:entity].hecks_name}##{parent_scalar}"

          # The auto-minted case (CommandInterpreter#entity_element): the
          # element just landed at count-so-far + 1. The explicit case: this
          # generator itself supplied whatever value sits at
          # args[identity_argument] — no guessing needed, it's read straight
          # back.
          new_id =
            if populator[:identity_argument]
              ValueGenerator.scalar_of(args[populator[:identity_argument].to_s])
            else
              (@entity_known_ids[key].size + 1).to_s
            end
          @entity_known_ids[key] << new_id
        end

        def pick_known(name)
          pool = @known_ids[name]
          return ValueGenerator.random_id(@random) if pool.empty? || @random.rand < ValueGenerator::INVALID_REFERENCE_PROBABILITY

          pool.sample(random: @random)
        end

        def pick_entity_known(aggregate_name, entity_name, parent_id)
          pool = @entity_known_ids["#{aggregate_name}.#{entity_name}##{parent_id}"]
          return ValueGenerator.random_id(@random) if pool.empty? || @random.rand < ValueGenerator::INVALID_REFERENCE_PROBABILITY

          pool.sample(random: @random)
        end
      end
    end
  end
end
