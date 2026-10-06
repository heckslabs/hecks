module Hecks
  module Fuzzing
    class SequenceGenerator
      # Replays another seed's generation as this seed's starting state, so a campaign can extend
      # a sequence that already reached somewhere rare.
      module Prefixing
        private

        # The prefix replay (when there is one), then this seed's own attempts.
        def generate_steps(runtime, catalog)
          steps = []
          if @prefix
            realize_prefix(runtime, catalog, @prefix, prefix_limit(@prefix), steps)
            restart_random(@seed)
            @favor = @own_favor
          end
          @step_count.times { steps << attempt_step(runtime, catalog) }
          steps.compact
        end

        # Re-runs the first `limit` attempts of another seed's generation (its own prefix
        # first), carrying its known ids and exercised verbs into this seed. The prefix is
        # on top of this seed's budget: taking it out of the budget left too little to explore.
        def realize_prefix(runtime, catalog, spec, limit, steps)
          return 0 unless limit.positive?

          inner = spec["prefix"]
          used  = inner ? realize_prefix(runtime, catalog, inner, [prefix_limit(inner), limit].min, steps) : 0
          restart_random(Integer(spec.fetch("seed")))
          @favor = Array(spec["favor"])
          (limit - used).times { steps << attempt_step(runtime, catalog) }
          limit
        end

        # Both streams restart together so a prefix replay draws the same query bindings.
        def restart_random(seed)
          @random         = Random.new(seed)
          @binding_random = Random.new(seed + QueryBinding::BINDING_SEED_OFFSET)
        end

        def prefix_limit(spec) = Integer(spec.fetch("steps")).clamp(0, @step_count)
      end
    end
  end
end
