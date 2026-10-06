module Hecks
  module Runtime
    class Registry
      # What dispatching produces: the event log, the reaction and saga logs, and the saga
      # instances in flight.
      #
      # `saga_dispatch_log` and `policy_dispatch_log` are Ruby-only; unlike `saga_log` and
      # `reaction_log` (ported byte-for-byte to rust/src/kernel/orchestrate.rs, per
      # spec/rust_conformance_spec.rb), they carry the raw dispatch-binding inputs
      # Properties.dispatch_binding_fidelity re-derives.
      RuntimeState = Struct.new(:event_log, :reaction_log, :reaction_events, :saga_log,
                                :saga_dispatch_log, :policy_dispatch_log, :saga_instances) do
        # @return [RuntimeState] every log empty and no saga instances
        def self.fresh
          new([], [], {}.compare_by_identity, [], [], [], Hash.new { |hash, key| hash[key] = {} })
        end

        # Empties every log and drops every saga instance.
        #
        # @return [void]
        def clear
          to_a.each(&:clear)
        end
      end
    end
  end
end
