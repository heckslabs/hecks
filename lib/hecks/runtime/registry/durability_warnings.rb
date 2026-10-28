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
        def warn_undurable_outbox!(hecksagon)
          bluebook_ir = bluebook(hecksagon.domain)
          return unless bluebook_ir && reactions_declared?(bluebook_ir)

          anchor = bluebook_ir.aggregates.first or return
          bind = Ports::Persistence::BindingPolicy.resolve(self, hecksagon.domain, anchor)
          return if adapter_class(bind.adapter) <= Ports::Persistence::RemoteRuntime
          return if repository(hecksagon.domain, anchor).outbox?

          warn undurable_outbox_wording(hecksagon, bind)
        rescue WiringError
          nil
        end

        def undurable_outbox_wording(hecksagon, bind)
          "[hecks] #{hecksagon.domain} declares policies/process_managers but its persistence adapter " \
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
          names = bluebook_ir.aggregates.flat_map do |aggregate|
            aggregate.commands.flat_map(&:emits) +
              aggregate.ports.flat_map { |port| port.operations.flat_map { |op| [*op.emits, op.answers, op.refuses] } }
          end
          names.compact.map(&:to_s)
        end

        # A hecksagon that never mentions persistence wires none, so its aggregates are in Memory:
        # the default, and nothing to say. The one case worth saying is a world that names a store
        # (a database or persistence settings) that no bind uses, which is a forgotten decision.
        def warn_unwired_persistence!(hecksagon)
          domain = hecksagon.domain
          return unless Ports::Persistence::BindingPolicy.unwired?(self, domain) && store_named?(domain)

          warn "[hecks] #{domain} names a store but binds no persistence, so its aggregates are in Memory " \
               "and keep nothing across a restart. Add `persisted_by \"<adapter>\"` to its hecksagon."
        end

        def store_named?(domain)
          !default_database_for(domain).nil? || !world(domain)&.for_verb("persistence").to_h.empty?
        end

        # A warning, not a refusal: running sagas on a store with no `save_saga` is
        # legitimate on purpose in a fast in-memory test/dev boot.
        def warn_undurable_sagas!(hecksagon)
          bluebook_ir = bluebook(hecksagon.domain)
          return unless bluebook_ir
          return if bluebook_ir.process_managers.empty?
          return unless saga_persistence(hecksagon.domain).equal?(Ports::Persistence::NULL_SAGA_STORE)

          names = bluebook_ir.process_managers.map(&:name).join(", ")
          warn "[hecks] #{hecksagon.domain} declares process_manager(s) #{names} but its resolved " \
               "persistence adapter has no save_saga — saga state advances correctly in-process " \
               "and is LOST on restart (no checkpoint, no rehydration, no compensation replay). " \
               "Bind this domain to an adapter that implements save_saga if this process_manager " \
               "must survive a crash."
        end
      end
    end
  end
end
