# frozen_string_literal: true

require_relative "started_work"
require_relative "console_capture"
require_relative "work_slots"
require_relative "dispatching/work_items"

module Hecks
  module Adapters
    # The `WorkLimits` port's adapter for `Tickets::Work`: the concurrency cap on started work
    # items.
    #
    # It reads the other Work items from the registry it is built with, the cap from the Tickets
    # world's `work_limit` setting. It decides nothing
    # about what happens next: the bluebook sends a refused start back to the plan.
    class WorkLimits
      # The cap when the Tickets world declares none.
      DEFAULT_CAP = 8

      # The places beyond the cap a red work item may take when the Tickets world declares none.
      DEFAULT_URGENT_RESERVE = WorkSlots::DEFAULT_RESERVE

      # The world verb that carries the cap.
      VERB = "work_limit"

      # @param registry [Runtime::Registry, nil] the booted registry whose Work items are read
      # @param aggregate [Object, nil] unused
      def initialize(registry: nil, aggregate: nil)
        @registry = registry
      end

      # The cap on started work items a registry's Tickets world declares.
      #
      # @param registry [Runtime::Registry, nil]
      # @return [Integer] the declared cap, else {DEFAULT_CAP}
      def self.cap(registry)
        declared = registry&.world("Tickets")&.for_verb(VERB)
        declared && !declared[:cap].nil? ? Integer(declared[:cap]) : DEFAULT_CAP
      end

      # The places beyond the cap that red work items may fill, from the world's `urgent_reserve`.
      #
      # @param registry [Runtime::Registry, nil]
      # @return [Integer] the declared reserve, else {DEFAULT_URGENT_RESERVE}
      def self.urgent_reserve(registry)
        declared = registry&.world("Tickets")&.for_verb(VERB)
        declared && !declared[:urgent_reserve].nil? ? Integer(declared[:urgent_reserve]) : DEFAULT_URGENT_RESERVE
      end

      # Clears a just-started work item against the cap.
      #
      # @param held [Hash] the Work item: `work`
      # @return [Hash{Symbol => Hash}] `output:` the line that says the cap holds
      # @raise [ConsoleCapture::Failure] naming the cap, the count and the holders
      def check_cap(**held)
        key = plain(held[:work])
        holders = started
        item = holders.find { |candidate| candidate.key == key }
        limit = self.class.cap(@registry)
        raise ConsoleCapture::Failure, refusal(key, limit, holders) if item && over?(item, holders - [item], limit)

        { output: { value: "#{key} is within the cap of #{limit} (#{holders.size} started)" } }
      end

      private

      def started
        StartedWork.items(@registry).map { |item| Dispatching::Plan::Item.new(key: item[:key], title: item[:title].to_s) }
      end

      def over?(item, others, limit)
        WorkSlots.full?(item, others, cap: limit, reserve: self.class.urgent_reserve(@registry))
      end

      def refusal(key, limit, holders)
        "#{key} would be started work item #{holders.size} of a cap of #{limit}; started: #{holders.map(&:key).join(", ")}"
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
