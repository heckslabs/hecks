# frozen_string_literal: true

require_relative "batching"
require_relative "dependencies"

module Hecks
  module Adapters
    class Dispatching
      # How a fill reads a group: the lead {Batching} makes of an `only=group:<path>`, and the line
      # each work item left waiting gets, which says a group is held and why. It reads the work
      # items and machine of the {Dispatching} that includes it.
      module BatchReads
        private

        # The planned work items an `only` holds a fill to: the lead of the group it names, or the
        # items whose key starts with it, or all of them when it is empty.
        def held_to(items, only)
          return batching(only).call(items) if Batching.group?(only)

          items.select { |item| only.empty? || item.key.to_s.start_with?(only) }
        end

        # The group an `only=group:<path>` asks for, as one lead carrying its batch.
        def batching(only)
          Batching.new(only, cap: machine.batch_cap, root: Plan::REPOSITORY, waits: Dependencies.new(work_items).method(:reason))
        end

        def skipped_line(skip)
          return "#{skip.key} #{skip.reason}" unless Batching.group_skip?(skip)

          "#{skip.key} held: #{skip.reason.delete_prefix("skipped: ")}"
        end
      end
    end
  end
end
