module Hecks
  module Runtime
    class Registry
      # Warns, never refuses, when a domain's reactions or sagas would not survive a crash.
      # Mixed into {Verification}.
      module DurabilityWarnings
        private

        # A domain with policies/a process_manager but no outbox on its bound adapter
        # (`AppendOnly#outbox?`) runs reactions inline — lost on a crash between a
        # commit and its reaction. A warning, not a refusal: Memory has an in-process
        # outbox, so dev/test stays quiet, but file/remote adapters need this to be loud.
        def warn_undurable_outbox!(hexagon)
          bluebook_ir = bluebook(hexagon.domain)
          return unless bluebook_ir && reactions_declared?(bluebook_ir)

          anchor = bluebook_ir.aggregates.first or return
          bind = Ports::Persistence::BindingPolicy.resolve(self, hexagon.domain, anchor)
          return if adapter_class(bind.adapter) <= Ports::Persistence::RemoteRuntime
          return if repository(hexagon.domain, anchor).outbox?

          warn undurable_outbox_wording(hexagon, bind)
        rescue WiringError
          nil
        end

        def undurable_outbox_wording(hexagon, bind)
          "[hecks] #{hexagon.domain} declares policies/process_managers but its persistence adapter " \
            "(#{bind.adapter}) has no outbox — reactions run inline and a crash between a command's commit " \
            "and its reactions loses them silently. Bind SqlitePersistence or Postgres for a durable outbox " \
            "(see Runtime::Outbox), or accept in-process-only reactions on purpose."
        end

        def reactions_declared?(bluebook_ir)
          !bluebook_ir.process_managers.empty? || any_policy_listens_to?(bluebook_ir)
        end

        def any_policy_listens_to?(bluebook_ir)
          emitted = emitted_event_names(bluebook_ir)
          @declared.bluebooks.each_value.any? do |candidate|
            candidate.policies.any? { |policy| emitted.include?(policy.event_name.to_s) }
          end
        end

        # The name of every event the aggregates' commands and port operations announce.
        def emitted_event_names(bluebook_ir)
          bluebook_ir.aggregates.flat_map do |aggregate|
            aggregate.commands.flat_map(&:emits) +
              aggregate.ports.flat_map { |port| port.operations.flat_map { |op| [*op.emits, op.answers, op.refuses] } }
          end.compact.map(&:to_s)
        end

        # A warning, not a refusal: running sagas on a store with no `save_saga` is
        # legitimate on purpose in a fast in-memory test/dev boot.
        def warn_undurable_sagas!(hexagon)
          bluebook_ir = bluebook(hexagon.domain)
          return unless bluebook_ir
          return if bluebook_ir.process_managers.empty?
          return unless saga_persistence(hexagon.domain).equal?(Ports::Persistence::NULL_SAGA_STORE)

          names = bluebook_ir.process_managers.map(&:name).join(", ")
          warn "[hecks] #{hexagon.domain} declares process_manager(s) #{names} but its resolved " \
               "persistence adapter has no save_saga — saga state advances correctly in-process " \
               "and is LOST on restart (no checkpoint, no rehydration, no compensation replay). " \
               "Bind this domain to an adapter that implements save_saga if this process_manager " \
               "must survive a crash."
        end
      end
    end
  end
end
