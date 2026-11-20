# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # Why a confirmed filling started nothing, said in one clause for the report's header, so a
      # roll that ends with no start records which step ended it.
      #
      # It only names what the plan and the queue already say: the plan's waits grouped by kind, and
      # the planned items a roll leaves out because no one marked them.
      class StopReason
        # The kinds a wait is grouped into, matched against the plan's reason text in order.
        KINDS = {
          /cap \d+ reached/ => "cap", /\Askipped: load/ => "load", /paused|boot/ => "pause", /overlaps/ => "area overlap",
          /frozen/ => "frozen", /epic/ => "epic", /parked|backoff|retry/ => "parked", /waits|depends/ => "dependency"
        }.freeze

        # @param skipped [Array<#reason>] the plan's waiting work items
        # @param unmarked [Integer] the planned items a roll does not consider (no priority)
        # @param chosen [Integer] how many work items the plan chose
        def initialize(skipped:, unmarked: 0, chosen: 0)
          @skipped = skipped
          @unmarked = unmarked
          @chosen = chosen
        end

        # @param reason [String] a wait's reason, as the plan words it
        # @return [String] the kind the wait is counted under, `other` when no pattern fits
        def self.kind_of(reason) = KINDS.find { |pattern, _| pattern.match?(reason) }&.last || "other"

        # @return [String] `"; nothing started: ..."`, or an empty string when something was chosen
        def clause = @chosen.positive? ? "" : "; nothing started: #{why}"

        private

        def why
          parts = counts.map { |kind, count| "#{count} held by #{kind}" }
          parts << "#{@unmarked} planned without a priority wait for a manual fill" if @unmarked.positive?
          parts.empty? ? "nothing planned" : parts.join(", ")
        end

        def counts = @skipped.map { |skip| self.class.kind_of(skip.reason) }.tally
      end
    end
  end
end
