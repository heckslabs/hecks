# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # Why a planned work item waits for another to land. A work item holds the keys it waits on
      # (`waits_on`, set by `Work.plan!` or `Work.wait_on!`); it may also name them in its detail,
      # on a line of its own: `Depends on: <work key>`, with more keys after commas.
      #
      # The detail line is a convention nothing validates, since a plan accepts any detail: a label
      # spelt another way names no dependency. It stands in for `waits_on` until the open work
      # items that carry one name their keys through `Work.wait_on!`, and is read beside it.
      #
      # A dependency is met when its work item is done, or when a landed `Landing` names its branch
      # ({LandingFacts#landed_commits}). A work item is done once its landing job finishes it or it
      # is finished with no change, so a done item no landing names still releases its waiters;
      # the landing releases them while the status is not yet settled.
      class Dependencies
        # The line of a detail that names dependencies, with the keys it names.
        NAMED = /^\s*depends?\s+on\s*:\s*(.+)$/i

        # What separates one named key from the next.
        BETWEEN = /[,\s]+/

        # @param item [#key, #detail] a work item; its `waits_on` is read when it answers to it
        # @return [Array<String>] the keys it waits on, then the keys its detail names, without its
        #   own
        def self.of(item)
          names = declared(item) + named_lines(item).flat_map { |(keys)| keys.split(BETWEEN) }
          names.map { |name| name.to_s.delete_suffix(".") }.reject(&:empty?).uniq - [item.key.to_s]
        end

        # @param item [#key] a work item
        # @return [Array<String>] the keys its `waits_on` holds, none when it has no such field
        def self.declared(item) = item.respond_to?(:waits_on) ? Array(item.waits_on) : []

        # @param item [#detail] a work item
        # @return [Array<Array<String>>] what follows the label on each line that names dependencies
        def self.named_lines(item) = item.detail.to_s.scan(NAMED)

        # @param work_items [#landed_commits, #status_of] reads the landings and the work items;
        #   asked only about a key some detail names
        def initialize(work_items)
          @work_items = work_items
          @met = {}
        end

        # @param item [#key, #detail] a planned work item
        # @return [String, nil] `skipped: waits on <key>` for the first named key that is not met,
        #   nil when the item names none or each is met
        def reason(item)
          key = self.class.of(item).find { |name| !met?(name) }
          "skipped: waits on #{key}#{note(key)}" if key
        end

        private

        def met?(key)
          @met.fetch(key) { @met[key] = done?(key) || @work_items.landed_commits(key).any? }
        end

        def done?(key) = @work_items.status_of(key) == "done"

        # Said when the named key can never be met, so a person sees it.
        def note(key)
          case @work_items.status_of(key)
          when nil then " (no such work item)"
          when "dropped" then " (dropped)"
          end
        end
      end
    end
  end
end
