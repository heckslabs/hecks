module Hecks
  module Runtime
    class Registry
      # A lent bind fits the borrower or is left out. A worktree loads its main checkout's local
      # files, which were written for that checkout's code; a bind there to an aggregate this
      # checkout does not declare is the lender's and no fault of this one, so it is dropped and
      # said once. A checkout's own bind to an undeclared aggregate is still refused.
      module LentBinds
        # What a dropped bind says: the aggregate, and how the borrower comes to keep it too.
        NOTE = "[hecks] the main checkout keeps %<aggregate>s, which this checkout does not declare: " \
               "left out here. Rebase onto main to keep it too.".freeze

        private

        # Drops the hecksagon's lent binds to aggregates its bluebook does not declare.
        def drop_lent_strangers!(hecksagon)
          strangers = hecksagon.binds.select { |bind| lent_stranger?(hecksagon, bind) }
          strangers.each { |bind| warn(format(NOTE, aggregate: bind.aggregate)) }
          hecksagon.binds.reject! { |bind| strangers.include?(bind) }
        end

        def lent_stranger?(hecksagon, bind)
          bind.lent && bind.aggregate && bluebook(hecksagon.domain)&.aggregate(bind.aggregate_name).nil?
        end
      end
    end
  end
end
