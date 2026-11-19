module Hecks
  module Runtime
    class Registry
      # A bind read from a gitignored local file fits the bluebook or is left out. A worktree loads
      # its main checkout's local files, written for that checkout's code; and a checkout's own
      # local files outlive an aggregate the bluebook retires. Either way a bind there to an
      # aggregate the bluebook does not declare is dropped and said, loudly, once per bind, so a
      # stale overlay never stops the launcher opening. A committed bind to one is still refused.
      module LentBinds
        # What a dropped bind says, by where it was read: the aggregate, and how to settle it.
        NOTES = {
          lent:  "[hecks] the main checkout keeps %<aggregate>s, which this checkout does not declare: " \
                 "left out here. Rebase onto main to keep it too.",
          local: "[hecks] a local hecksagon binds %<aggregate>s, which the bluebook does not declare: " \
                 "left out, so it is not kept. Remove the line from the local hecksagon that names it " \
                 "(`exe/hecks LocalOverlay.write!` rewrites hecks.local.hecksagon from its rows)."
        }.freeze

        private

        # Drops the hecksagon's local binds to aggregates its bluebook does not declare.
        def drop_lent_strangers!(hecksagon)
          strangers = hecksagon.binds.select { |bind| lent_stranger?(hecksagon, bind) }
          strangers.each { |bind| warn(format(NOTES.fetch(bind.provenance), aggregate: bind.aggregate)) }
          hecksagon.binds.reject! { |bind| strangers.include?(bind) }
        end

        def lent_stranger?(hecksagon, bind)
          bind.provenance && bind.aggregate && bluebook(hecksagon.domain)&.aggregate(bind.aggregate_name).nil?
        end
      end
    end
  end
end
