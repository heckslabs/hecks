# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # A {Plan}'s hold on the members of a batch: a planned work item that names the lead whose
      # batch holds it is built by that lead's session, so it never starts on its own and does not
      # count against the cap.
      module PlanBatch
        private

        # The wait of a work item, named for its group when it leads one.
        def skip_of(item, reason) = Plan::Skip.new(Batching.name_of(item), reason)

        def batch_reason(item)
          "skipped: held: in the batch of #{item.batch}" unless item.batch.to_s.empty?
        end
      end
    end
  end
end
