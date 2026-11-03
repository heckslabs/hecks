# frozen_string_literal: true

require_relative "started_work"
require_relative "console_capture"

module Hecks
  module Adapters
    # The `WorkLimits` port's adapter for `Tickets::Work`: the concurrency cap on started rows.
    #
    # It reads the other Work rows from the registry it is built with, the cap from the Tickets
    # world's `work_limit` setting. It decides nothing
    # about what happens next: the bluebook sends a refused start back to the plan.
    class WorkLimits
      # The cap when the Tickets world declares none.
      DEFAULT_CAP = 8

      # The world verb that carries the cap.
      VERB = "work_limit"

      # @param registry [Runtime::Registry, nil] the booted registry whose Work rows are read
      # @param aggregate [Object, nil] unused
      def initialize(registry: nil, aggregate: nil)
        @registry = registry
      end

      # The cap on started rows a registry's Tickets world declares.
      #
      # @param registry [Runtime::Registry, nil]
      # @return [Integer] the declared cap, else {DEFAULT_CAP}
      def self.cap(registry)
        declared = registry&.world("Tickets")&.for_verb(VERB)
        declared && !declared[:cap].nil? ? Integer(declared[:cap]) : DEFAULT_CAP
      end

      # Clears a just-started row against the cap.
      #
      # @param held [Hash] the Work row: `work`
      # @return [Hash{Symbol => Hash}] `output:` the line that says the cap holds
      # @raise [ConsoleCapture::Failure] naming the cap, the count and the holders
      def check_cap(**held)
        key = plain(held[:work])
        holders = StartedWork.rows(@registry).map { |row| row[:key] }
        limit = self.class.cap(@registry)
        if holders.include?(key) && holders.size > limit
          raise ConsoleCapture::Failure,
                "#{key} would be started row #{holders.size} of a cap of #{limit}; started: #{holders.join(", ")}"
        end

        { output: { value: "#{key} is within the cap of #{limit} (#{holders.size} started)" } }
      end

      private

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
