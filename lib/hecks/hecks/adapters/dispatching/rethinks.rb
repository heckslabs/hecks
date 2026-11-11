# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # What the architect's rethink verdicts on a Work item say to the coder that starts next. The
      # reviews are the PlanReview rows, the single record of each verdict and its findings, so the
      # section is derived on every read and a review appears in it once, by its run key.
      class Rethinks
        # What the next coder is told before anything else in its brief.
        LEAD = "A previous plan was rejected: findings below; plan from them."

        # The number of rethinks that stops a Work item when the world names none.
        LIMIT = 3

        # @param reviews [Array<Hash>] each review as `run:`, `work:`, `verdict:` and `findings:`
        # @param limit [Integer] the rethinks that stop a Work item
        def initialize(reviews, limit: LIMIT)
          @reviews = reviews
          @limit = limit
        end

        # @param work [String] a Work item's key
        # @return [Array<Hash>] its rethink reviews, in the order they were recorded
        def for(work) = @reviews.select { |review| review[:work].to_s == work && review[:verdict].to_s == "rethink" }

        # @param work [String] a Work item's key
        # @return [String] the brief section: the lead and one block for each review, empty when
        #   the architect never said rethink
        def section(work)
          found = self.for(work)
          return "" if found.empty?

          ([LEAD] + found.map { |review| block(review) }).join("\n\n")
        end

        # @param work [String] a Work item's key
        # @return [String, nil] why the Work item does not start: it has reached the limit
        def stop_reason(work)
          found = self.for(work)
          return if found.size < @limit

          "skipped: needs a person: #{found.size} architect rethinks (#{found.map { |r| r[:run] }.join(", ")})"
        end

        private

        def block(review) = "Review #{review[:run]} (rethink):\n#{review[:findings]}"
      end
    end
  end
end
