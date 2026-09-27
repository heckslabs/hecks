module Hecks
  module Fuzzing
    class SequenceGenerator
      # Which step to try next: eligibility (what is possible from the
      # state so far) and weighting (what is likely to reach somewhere
      # new).
      module Picker
        private

        def pick(catalog)
          rest = catalog[:queries].dup
          catalog[:instance].each { |entry| rest << entry if actionable?(catalog, entry) }
          catalog[:entity_commands].each { |entry| rest << entry if actionable?(catalog, entry) }
          catalog[:entity_queries].each { |entry| rest << entry if @known_ids[entry[:aggregate].hecks_name].any? }
          catalog[:read_models].each { |entry| rest << entry if read_model_actionable?(entry) }

          makers = catalog[:creating].select { |entry| satisfiable?(catalog, entry) }
          pool   = rest + makers.flat_map { |entry| [entry] * creating_weight(rest.size) }
          pool  += deep_entity_bias(rest) if adversarial?

          steer(pool).sample(random: @random)
        end

        # Weights up entity commands two or more hops deep; adversarial mode only,
        # and eligibility still decides what is possible.
        def deep_entity_bias(rest)
          deep = rest.select { |entry| (entry[:chain] || []).size >= Adversary::DEEP_ENTITY_DEPTH }
          deep * Adversary::DEEP_ENTITY_WEIGHT
        end

        # While the store is empty, creation matches everything else combined, so a
        # run does not spend its budget querying nothing.
        def creating_weight(rest_size)
          return CREATING_WEIGHT if @known_ids.each_value.any?(&:any?)

          [rest_size, CREATING_WEIGHT].max
        end

        def actionable?(catalog, entry)
          @known_ids[entry[:aggregate].hecks_name].any? && satisfiable?(catalog, entry)
        end

        # A rootless report is always eligible; a rooted one needs an instance of its
        # `reference_target`, or the ask is refused.
        def read_model_actionable?(entry)
          entry[:model].reference_target.nil? || @known_ids[entry[:model].reference_target].any?
        end

        # A command whose references point at nothing that exists is refused, so it
        # is withheld until they do. A target no creating command can make (a
        # cross-domain reference) is exempt, or the domain would starve.
        def satisfiable?(catalog, entry)
          entry[:command].attributes.select(&:reference?).all? do |attribute|
            target = attribute.type.target_name.to_s
            !catalog[:creatable].include?(target) || @known_ids[target].any?
          end
        end

        # Weights up verbs this sequence has not dispatched yet. Only likelihood
        # changes; a verb gated behind missing state stays out of the pool.
        def steer(pool)
          fresh = pool.reject { |entry| @exercised.include?(entry[:verb]) }
          steered = fresh.empty? ? pool : pool + (fresh * UNEXERCISED_WEIGHT)
          favor(steered)
        end

        # Weights up the `favor:` verbs when eligible, never making one eligible.
        def favor(pool)
          return pool if @favor.empty?

          favored = pool.uniq.select { |entry| @favor.include?(entry[:verb]) }
          pool + (favored * SequenceGenerator::FAVOR_WEIGHT)
        end
      end
    end
  end
end
