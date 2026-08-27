require_relative "../value_generator"
require_relative "../../naming"

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
          parent_scalar = identity_scalar_of(aggregate, args)

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

        # THE SCALAR THIS STEP'S OWN AGGREGATE IDENTITY RESOLVES TO, from the
        # args a creating (or entity-populating) command actually
        # dispatched — a SINGLE declared head (or the untyped default
        # `:id`) reads straight off its own top-level arg the way this
        # always has (`ValueGenerator.scalar_of`, opening the identity value
        # object). A genuinely COMPOSITE identity (`composite_identity?`,
        # shared with StepBuilder#add_identity! — see its own comment) has
        # no such top-level arg at all: `add_identity!` deliberately leaves
        # a composite creating command's own individually-declared fields
        # alone rather than forcing a synthetic `id` neither the bluebook
        # nor the command ever declared, so this joins those fields itself,
        # in the SAME declaration order `Runtime::Identity.of` joins them
        # at dispatch (`Naming.identity`, `Naming::IDENTITY_JOIN`) — which
        # is exactly what makes the result usable later as the bare `id:`
        # a composite Revoke/act-again command expects (`Identity.from`'s
        # own untyped fallback, reached when `identity_of` finds no
        # top-level field args to join, reads a bare `id:` straight
        # through unattributed).
        def identity_scalar_of(aggregate, args)
          parent_key = (aggregate.identified_by || :id).to_s
          return ValueGenerator.scalar_of(args[parent_key]) unless composite_identity?(aggregate)

          parts = aggregate.identity_paths.map { |path| ValueGenerator.scalar_of(args[path.to_s.split(".").first]) }
          Naming.identity(parts)
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
