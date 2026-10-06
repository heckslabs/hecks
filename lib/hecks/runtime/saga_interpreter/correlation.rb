require_relative "../value"

module Hecks
  module Runtime
    class SagaInterpreter
      # How a saga decides which conversation an event belongs to.
      module Correlation
        private

        # Resolves the correlation key in three tiers: the payload path, the stamp from
        # the dispatching saga, then the emitting record's own identity.
        # A dotted path (`:"end_to_end.value"`) names one scalar; a whole value object
        # has no single unambiguous rendering as a key.
        def saga_correlation(process_manager, event)
          value = payload_correlation(process_manager, event)
          return value unless value.to_s.empty?

          stamped = stamped_correlation(process_manager, event)
          return stamped unless stamped.nil? || stamped.to_s.empty?

          # A self-referencing leg correlates by `event.id`: routing keys never ride in the
          # payload, so a payload dig finds nothing for legs with no declared attributes.
          # Gated on the head being the aggregate's own identity, so an unrelated aggregate
          # emitting a same-named event is not read as this saga's conversation.
          self_identified?(process_manager, event) ? event.id : nil
        end

        # The payload path's own value. A downstream event may carry the bare scalar already.
        # Strings respond to `[]`, so test for Hash/Value explicitly rather than
        # `respond_to?(:[])`.
        def payload_correlation(process_manager, event)
          path = process_manager.correlates_by.to_s.split(".")
          path.reduce(event.payload) do |held, segment|
            held.is_a?(Hash) || held.is_a?(Value) ? held[segment.to_sym] : held
          end
        end

        # The stamp `deliver_saga_dispatch` puts on its own event, for legs whose command
        # carries no correlation field. Keyed by `correlation_head` so another saga
        # correlating on a different field cannot misread it.
        def stamped_correlation(process_manager, event)
          event.correlation && event.correlation[process_manager.correlation_head.to_s]
        end

        def self_identified?(process_manager, event)
          domain, bare_name = event.aggregate.to_s.split("::", 2)
          return false unless bare_name

          construct = @registry.bluebook(domain)&.aggregate(bare_name)
          return false unless construct

          construct.identity_heads.map(&:to_s).include?(process_manager.correlation_head.to_s)
        end
      end
    end
  end
end
