module Hecks
  module Runtime
    class Registry
      # The refusal that keeps a saga as durable as the aggregates it moves (ADR 0170): a process
      # manager whose checkpoints no store keeps may not dispatch to an aggregate a store keeps
      # across a restart. All-Memory stays allowed and keeps its warning. Mixed into {Verification}.
      module SagaDurabilityRule
        private

        # Reads every declared bluebook, not each hecksagon: a domain kept by its world's
        # `default_adapter` or by an attaching chapter has process managers too.
        def refuse_forgetful_sagas!
          @declared.bluebooks.each_key do |domain|
            process_managers_of(domain).each { |process_manager| refuse_forgetful_saga!(domain, process_manager) }
          end
        end

        def refuse_forgetful_saga!(domain, process_manager)
          return unless saga_persistence(domain, process_manager).equal?(Ports::Persistence::NULL_SAGA_STORE)

          kept = dispatched_aggregates(domain, process_manager).find { |aggregate| kept_across_restart(domain, aggregate) }
          return unless kept

          raise WiringError, forgetful_saga_wording(domain, process_manager, kept)
        end

        # The domain's own aggregates a process manager's legs and compensations dispatch to.
        def dispatched_aggregates(domain, process_manager)
          names = dispatch_specs(process_manager).map { |spec| aggregate_of_command(spec.command_name) }
          bluebook(domain).aggregates.select { |aggregate| names.include?(aggregate.name.to_s) }
        end

        def dispatch_specs(process_manager)
          process_manager.handlers.flat_map(&:dispatches).flat_map { |spec| [spec, spec.compensates].compact }
        end

        # `"Drawer.Take"` or `"Wire::Drawer.Take"` names the aggregate `Drawer`.
        def aggregate_of_command(command_name)
          path = command_name.to_s.split(".", 2).first
          path.to_s.split("::").last
        end

        # The adapter that keeps the aggregate across a restart, or nil. Memory keeps nothing, and
        # a RemoteRuntime's far side keeps the saga as well as the record. An aggregate whose bind
        # cannot be resolved is left to the refusal that resolution raises at dispatch.
        def kept_across_restart(domain, aggregate)
          bind = Ports::Persistence::BindingPolicy.resolve(self, domain, aggregate)
          return nil if bind.adapter == Ports::Persistence::DEFAULT_ADAPTER
          return nil if adapter_class(bind.adapter) <= Ports::Persistence::RemoteRuntime

          bind.adapter
        rescue WiringError
          nil
        end

        def forgetful_saga_wording(domain, process_manager, aggregate)
          "#{domain}'s process_manager #{process_manager.name} dispatches to #{aggregate.name}, which " \
            "#{kept_across_restart(domain, aggregate)} keeps across a restart, but its own checkpoints are kept " \
            "nowhere — after a restart the records stay moved and the saga that would finish or undo the move is " \
            "gone. A forgotten decision: persist the aggregate it starts from (or the domain's first aggregate) " \
            "with an adapter that keeps sagas, or keep the whole domain in Memory on purpose (ADR 0170)."
        end
      end
    end
  end
end
