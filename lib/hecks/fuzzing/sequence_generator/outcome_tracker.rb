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
          record_grant(args) if catalog[:grant_verbs].include?(entry[:verb])

          populator = populator_for_entry(catalog, entry)
          return unless populator

          key = append_pool_key(populator, args)

          # Auto-minted identities land at count-so-far + 1; an explicit one is
          # read back from the args this generator supplied.
          new_id =
            if populator[:identity_argument]
              ValueGenerator.scalar_of(args[populator[:identity_argument].to_s])
            else
              (@entity_known_ids[key].size + 1).to_s
            end
          @entity_known_ids[key] << new_id

          # Keep the caller-supplied identity tuple whole so the duplicate-identity
          # mutation can offer it again under the same parent.
          return if populator[:identity_arguments].empty?

          @appended_identities[key] << populator[:identity_arguments].to_h { |name| [name.to_s, args[name.to_s]] }
        end

        # Records a grant that took effect: `actor_id` now holds `role_name`, which
        # lets the `actor_known` caller shape reach the authorized branch.
        def record_grant(args)
          role  = ValueGenerator.scalar_of(args["role_name"]).to_s
          actor = ValueGenerator.scalar_of(args["actor_id"]).to_s
          @granted[role] << actor unless role.empty? || actor.empty?
        end

        # The pool an appended element lands in: the aggregate's identity, then
        # one scalar per owning hop (none for an aggregate-level append).
        def append_pool_key(populator, args)
          parent_scalar = identity_scalar_of(populator[:aggregate], args)
          owner_scalars = populator[:owner_chain].map do |piece|
            ValueGenerator.scalar_of(args[(piece.identified_by || :id).to_s])
          end
          entity_pool_key(populator[:aggregate].hecks_name,
                          populator[:owner_chain].map(&:hecks_name) + [populator[:entity].hecks_name],
                          [parent_scalar] + owner_scalars)
        end

        # `"Agg.Board#w1"` for a depth-1 pool, `"Agg.Board.Card#w1/1"` one hop
        # deeper. Depth-1 keys must stay stable for pinned seeds.
        def entity_pool_key(aggregate_name, chain_names, scalars)
          "#{aggregate_name}.#{chain_names.join(".")}##{scalars.join("/")}"
        end

        # The scalar the step's aggregate identity resolves to. A composite identity
        # has no top-level arg, so its parts are joined in the order
        # `Runtime::Identity.of` joins them, yielding a usable bare `id:` later.
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

        def pick_entity_known(key)
          pool = @entity_known_ids[key]
          return ValueGenerator.random_id(@random) if pool.empty? || @random.rand < ValueGenerator::INVALID_REFERENCE_PROBABILITY

          pool.sample(random: @random)
        end
      end
    end
  end
end
