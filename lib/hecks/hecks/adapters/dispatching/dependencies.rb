# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # Why a planned work item waits for another to land. An item names what it depends on in its
      # detail, on a line of its own: `Depends on: <work key>`, with more keys after commas.
      #
      # The line is a convention nothing validates, since a plan accepts any detail: a label spelt
      # another way names no dependency and the item starts. It stands in for a dependency the
      # `Tickets::Work` aggregate would hold itself.
      #
      # A dependency has landed when a landed `Landing` names its branch, which is what
      # {LandingFacts#landed_commits} reads. A work item finished at its submission is done before
      # its landing job runs, so its status alone does not say so.
      class Dependencies
        # The line of a detail that names dependencies, with the keys it names.
        NAMED = /^\s*depends?\s+on\s*:\s*(.+)$/i

        # What separates one named key from the next.
        BETWEEN = /[,\s]+/

        # @param item [#key, #detail] a work item
        # @return [Array<String>] the keys its detail names, without its own
        def self.of(item)
          names = named_lines(item).flat_map { |(keys)| keys.split(BETWEEN) }
          names.map { |name| name.delete_suffix(".") }.reject(&:empty?).uniq - [item.key.to_s]
        end

        # @param item [#detail] a work item
        # @return [Array<Array<String>>] what follows the label on each line that names dependencies
        def self.named_lines(item) = item.detail.to_s.scan(NAMED)

        # @param work_items [#landed_commits, #status_of] reads the landings and the work items;
        #   asked only about a key some detail names
        def initialize(work_items)
          @work_items = work_items
          @landed = {}
        end

        # @param item [#key, #detail] a planned work item
        # @return [String, nil] `skipped: waits on <key>` for the first named key that has not
        #   landed, nil when the item names none or each has landed
        def reason(item)
          key = self.class.of(item).find { |name| !landed?(name) }
          "skipped: waits on #{key}#{note(key)}" if key
        end

        private

        def landed?(key)
          @landed.fetch(key) { @landed[key] = @work_items.landed_commits(key).any? }
        end

        # Said when no landing can end the wait, so a person sees it.
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
