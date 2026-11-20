# frozen_string_literal: true

require_relative "../area_overlap"

module Hecks
  module Adapters
    class Dispatching
      # The group a fill hands to one coder when it is asked for `only=group:<path>`: the planned
      # work items whose areas overlap the path, in plan order, held to the batch cap. The first is
      # the lead, the one work item the fill starts; it carries the others as its members and holds
      # the union of their areas, so the cap and the area guard reason about one session.
      #
      # The lead is the first in plan order, so the group's priority is its highest member's, unless
      # a work item of the group already leads members committed on its branch (a batch sent back
      # to the plan for load): that one leads again, the first of them in plan order when there are
      # several, so the batch resumes on the branch that holds those commits. A member still waiting
      # on an unlanded dependency is left out, and the members past the cap stay planned: they
      # overlap the lead's area, so they wait for its landing, the next batch.
      class Batching
        # The prefix of an `only` that names a group rather than a key.
        PREFIX = "group:"

        # The members a batch holds when the world names no `work_group_cap`.
        CAP = 6

        # @param only [String] the fill's `only`
        # @return [Boolean] whether it names a group
        def self.group?(only) = only.to_s.start_with?(PREFIX)

        # @param item [Plan::Item] a work item a fill chose or left waiting
        # @return [String] `group <path> (N items)` for the lead of a group, else its key
        def self.name_of(item) = item.group ? "group #{item.group} (#{Array(item.batched).size + 1} items)" : item.key

        # @param skip [Plan::Skip] a work item left waiting
        # @return [Boolean] whether it is a group's lead, which the report says is held
        def self.group_skip?(skip) = skip.key.start_with?("group ")

        # @param only [String] the fill's `only`, `group:<path>`
        # @param cap [Integer] the most work items one batch holds, its lead included
        # @param root [String] the repository's top level, which a relative area is read against
        # @param waits [#call, nil] the unlanded work item an item waits on, nil when none
        def initialize(only, cap:, root:, waits: nil)
          @path = only.to_s.delete_prefix(PREFIX)
          @cap = cap
          @root = root
          @waits = waits
        end

        # @param planned [Array<Plan::Item>] the planned work items, in plan order
        # @return [Array<Plan::Item>] the lead with its members, or none when nothing overlaps
        def call(planned)
          batch = resumed_first(planned.select { |item| member?(item) }, planned).first(@cap)
          return [] if batch.empty?

          lead, *members = batch
          [Plan::Item.new(**lead.to_h, batched: members, group: @path, area: batch.flat_map(&:area).uniq)]
        end

        private

        # The group with a work item that leads committed members moved to the front.
        def resumed_first(group, planned)
          leads = planned.map { |item| item.batch.to_s }.reject(&:empty?)
          resuming = group.find { |item| leads.include?(item.key) }
          resuming ? [resuming, *(group - [resuming])] : group
        end

        def member?(item)
          item.batch.to_s.empty? && !@waits&.call(item) && AreaOverlap.first_overlap([@path], item.area, root: @root)
        end
      end
    end
  end
end
