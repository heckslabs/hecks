module Hecksagain
  module Fuzzing
    class SequenceGenerator
      # Which step to try next: eligibility (what is POSSIBLE from the
      # state so far) and weighting (what is LIKELY to reach somewhere
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

          steer(pool).sample(random: @random)
        end

        # WHILE THERE IS NOTHING TO FIND, MAKING SOMETHING IS THE ONLY USEFUL MOVE.
        #
        # A flat weight is right once the domain has records in it, and badly
        # wrong before: banking declares ten queries, and from an empty store
        # exactly ONE creating command is satisfiable — Customer.Register, the
        # verb the whole cascade waits on. Two entries against ten left runs
        # spending their entire budget querying a store nothing had been written
        # to ; one seed answered ten empty queries in a row and emitted nothing
        # at all.
        #
        # So while nothing exists, creation matches everything else put together.
        # After that the ordinary weight applies and the run gets on with
        # exercising what it made.
        def creating_weight(rest_size)
          return CREATING_WEIGHT if @known_ids.each_value.any?(&:any?)

          [rest_size, CREATING_WEIGHT].max
        end

        def actionable?(catalog, entry)
          @known_ids[entry[:aggregate].hecks_name].any? && satisfiable?(catalog, entry)
        end

        # A ROOTLESS report (no `reference_to` at all) has nothing to wait
        # for — it reads whole tables, the same "always eligible" position
        # `catalog[:queries]` itself takes. A ROOTED one needs a real
        # instance of its own `reference_target` to ask about first, same
        # rule `actionable?` already gives an instance command — asking
        # `Banking.disputed_payment_count` before any Account exists would
        # just be refused (`refuse_object_reference`/`NotFound`) the same
        # way `Account.Credit` would be, for the identical reason.
        def read_model_actionable?(entry)
          entry[:model].reference_target.nil? || @known_ids[entry[:model].reference_target].any?
        end

        # A COMMAND THAT REFERENCES NOTHING THAT EXISTS CANNOT SUCCEED, so it is
        # not offered until something does.
        #
        # `ValueGenerator.reference_value` has no real id to hand over when its
        # pool is empty, so it mints `missing-…` and the dispatch is refused
        # before it starts — a guaranteed waste of a step, and worse, one that
        # never fills the pool it was waiting on. Banking cascades from it:
        # Account.Open needs a Customer, ATMCard.Issue needs an Account,
        # Transfer.Request needs two, so a run that opened with the wrong verb
        # spent its whole budget being refused.
        #
        # This is the rule instance commands already follow — `known_ids.any?` —
        # applied to what a command REFERENCES rather than to what it acts on.
        # A target no creating command in this corpus can make (a cross-domain
        # reference, which `CommandRules#resolve_references` skips anyway) is
        # exempt, or the whole domain would starve waiting for it.
        def satisfiable?(catalog, entry)
          entry[:command].attributes.select(&:reference?).all? do |attribute|
            target = attribute.type.target_name.to_s
            !catalog[:creatable].include?(target) || @known_ids[target].any?
          end
        end

        # Coverage-guided rather than uniformly random : a verb this sequence has
        # not dispatched yet is weighted up, so a run spends its budget on the
        # commands it has not reached instead of re-rolling the ones it has. The
        # eligibility rules above still decide what is POSSIBLE — this only decides
        # what is likely, so a verb gated behind state it does not have yet stays
        # out of the pool entirely rather than being preferred forever.
        def steer(pool)
          fresh = pool.reject { |entry| @exercised.include?(entry[:verb]) }
          return pool if fresh.empty?

          pool + (fresh * UNEXERCISED_WEIGHT)
        end
      end
    end
  end
end
