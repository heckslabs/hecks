# frozen_string_literal: true

require_relative "started_work"
require_relative "session_inbox"

module Hecks
  module Adapters
    # What is true of the answers bound for one run: whether one waits in the session's inbox, is on
    # its way to the session, or is a verdict judged for the run's Work item and not yet delivered.
    # The `TurnFacts` adapter reads it for the end of a turn and for a submission.
    #
    # It reads three raw facts and judges none: whether any of them holds the coder back is the
    # Coder bluebook's.
    class UnreadAnswers
      # The states of an `Agents::Verdict` judged for a coder and not delivered to it.
      UNDELIVERED = %w[judged unresumed].freeze

      # @param registry [Runtime::Registry, nil] the booted registry, read for Verdict rows
      # @param inbox [#path] where an answer for a session waits (see {SessionInbox})
      def initialize(registry:, inbox: SessionInbox.new)
        @registry = registry
        @inbox = inbox
      end

      # @param run [Object] the `AgentRun` record answers are bound for
      # @param work [String] the key of the Work item the run serves
      # @return [Hash{Symbol => Boolean}] `inbox:` an answer waits in the session's inbox,
      #   `resuming:` an answer is on its way, `pending:` a verdict for the item is undelivered
      def of(run, work)
        key = StartedWork.value(run, :run).to_s
        { inbox: File.exist?(@inbox.path(key)), resuming: StartedWork.value(run, :resuming) == true,
          pending: pending?(work) }
      end

      private

      def pending?(work)
        verdicts.any? do |verdict|
          StartedWork.value(verdict, :work).to_s == work && UNDELIVERED.include?(StartedWork.value(verdict, :status).to_s)
        end
      end

      def verdicts
        declared = @registry&.bluebook("Agents")&.aggregates || []
        aggregate = declared.find { |candidate| candidate.hecks_name == "Verdict" }
        aggregate ? @registry.repository("Agents", aggregate).all : []
      end
    end
  end
end
