# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # How a {Plan} names a group's lead it leaves waiting: by the group and its size, so the
      # report says which group is held. A batched member is out of the plan, so the plan never
      # sees it and it takes no place under the cap.
      module PlanBatch
        private

        # The wait of a work item, named for its group when it leads one.
        def skip_of(item, reason) = Plan::Skip.new(Batching.name_of(item), reason)
      end
    end
  end
end
