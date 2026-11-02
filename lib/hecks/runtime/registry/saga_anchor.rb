module Hecks
  module Runtime
    class Registry
      # Which aggregate's store holds a process manager's checkpoints: the one aggregate whose
      # command emits the event the process manager starts on, when the domain's hecksagon binds
      # that aggregate on its own. A process manager with no such aggregate is held by the
      # domain's store. Mixed into {SagaPersistence}.
      module SagaAnchor
        # @param domain [String, Symbol] the domain declaring the process manager
        # @param process_manager [Bluebook::ProcessManager, String] the process manager or its name
        # @return [Bluebook::Aggregate, nil] the starting aggregate with a bind of its own, or nil
        def saga_anchor(domain, process_manager)
          declared = declared_process_manager(domain, process_manager) or return nil
          starters = starting_aggregates(domain, declared.starts_on.to_s)
          return nil unless starters.size == 1 && bound_on_its_own?(domain, starters.first)

          starters.first
        end

        private

        # Every process manager of the domain whose store is not the domain's own, by name.
        def routed_sagas(domain)
          home = saga_persistence(domain)
          stores = process_managers_of(domain).to_h { |declared| [declared.name, saga_persistence(domain, declared)] }
          stores.reject { |_name, store| store.equal?(home) }
        end

        def process_managers_of(domain) = bluebook(domain)&.process_managers || []

        def declared_process_manager(domain, process_manager)
          return process_manager if process_manager.respond_to?(:starts_on)

          process_managers_of(domain).find { |declared| declared.name == process_manager.to_s }
        end

        def starting_aggregates(domain, event_name)
          return [] if event_name.empty?

          bluebook(domain).aggregates.select do |aggregate|
            aggregate.commands.any? { |command| command.emits.map(&:to_s).include?(event_name) }
          end
        end

        def bound_on_its_own?(domain, aggregate)
          binds = hecksagon(domain)&.binds || []
          binds.any? do |bind|
            bind.aggregate_name.to_s == aggregate.hecks_name.to_s && bind.verb.to_s == Ports::Persistence::VERB
          end
        end
      end
    end
  end
end
