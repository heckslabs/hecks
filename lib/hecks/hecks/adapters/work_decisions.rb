# frozen_string_literal: true

require_relative "console_capture"
require_relative "started_work"

module Hecks
  module Adapters
    # The `WorkDecisions` port's adapter for `Tickets::Work`: says whether the decision a step was
    # planned or reopened under is accepted (ADR 0175).
    #
    # It reads the work item's `Tickets::Adr` record from the registry it is built with. An accepted
    # decision clears the work item; a proposed, withdrawn or superseded one refuses it by name, and
    # the bluebook lapses the work item with that refusal.
    class WorkDecisions
      STANDING = "accepted"

      # @param registry [Runtime::Registry, nil] the booted registry whose Adr rows are read
      # @param aggregate [Object, nil] unused
      def initialize(registry: nil, aggregate: nil)
        @registry = registry
      end

      # Clears a step whose decision is accepted.
      #
      # @param held [Hash] the work item: `work` and `decision`
      # @return [Hash{Symbol => Hash}] `output:` the line naming the decision the item carries out
      # @raise [ConsoleCapture::Failure] naming the step, its decision and the decision's status
      def check_decision(**held)
        key = plain(held[:work])
        number = plain(held[:decision])
        status = status_of(number)
        raise ConsoleCapture::Failure, refusal(key, number, status) unless status == STANDING

        { output: { value: "#{key} carries out ADR #{number}" } }
      end

      private

      def refusal(key, number, status)
        return "#{key} names no decision: plan it under an accepted ADR" if number.empty?
        return "#{key} names ADR #{number}, which no record holds" unless status

        "#{key} names ADR #{number}, which is #{status}, not accepted: accept it first with Adr.accept!"
      end

      def plain(argument)
        return argument.to_s unless argument.is_a?(Hash)

        (argument.key?(:value) ? argument[:value] : argument[:id]).to_s
      end

      def status_of(number)
        record = adr_repository&.find(number)
        record && StartedWork.value(record, :status).to_s
      end

      def adr_repository
        aggregate = adr_aggregate
        aggregate && @registry.repository("Tickets", aggregate)
      end

      def adr_aggregate
        bluebook = @registry&.bluebook("Tickets")
        bluebook&.aggregates&.find { |candidate| candidate.hecks_name == "Adr" }
      end
    end
  end
end
