# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaEventPump
      # The reactions the pump has made, kept as the ledger's `EventReaction` rows: one per
      # (consumer, event, policy). The pump asks before it runs a policy, and records the reaction
      # once the policy's command has answered, delivered or refused. The keys are read once, on
      # first use, and kept for the run, so a pass costs one query however many events it reads.
      class Reactions
        # @param runtime [Hecks::Runtime::Dispatcher] the booted ledger the rows live in
        def initialize(runtime)
          @runtime = runtime
          @known = nil
        end

        # @param consumer [String] the domain whose policy would run
        # @param event_id [String] the id of the event the policy would react to
        # @param policy [String] the policy's name
        # @return [Boolean] whether the ledger already holds this reaction
        def recorded?(consumer, event_id, policy)
          known.include?(key(consumer, event_id, policy))
        end

        # @param consumer [String] the domain whose policy answered
        # @param event_id [String] the id of the event it answered
        # @param policy [String] the policy's name
        # @return [void]
        def record(consumer, event_id, policy)
          row = key(consumer, event_id, policy)
          @runtime.dispatch_flat("QualityControl::EventReaction.Record", key: row, consumer: consumer,
                                                                         event_id: event_id, policy: policy)
          known << row
        end

        private

        def known
          @known ||= @runtime.query("QualityControl::EventReaction.All").to_set { |row| row[:key][:value] }
        end

        def key(consumer, event_id, policy) = "#{consumer}/#{event_id}/#{policy}"
      end
    end
  end
end
