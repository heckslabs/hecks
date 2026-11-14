module Hecks
  module Runtime
    class Registry
      # Which aggregate's store holds a process manager's checkpoints: the one aggregate whose
      # command emits the event the process manager starts on, when the hecksagon of the bluebook
      # that declares that aggregate binds it on its own. The aggregate is the domain's own, or,
      # when the domain declares no such event, one of a bluebook it is loaded with: a process
      # manager that starts on an attached bluebook's event is kept with that bluebook's record. A
      # process manager with no such aggregate is held by the domain's store. Mixed into
      # {SagaPersistence}.
      module SagaAnchor
        # @param domain [String, Symbol] the domain declaring the process manager
        # @param process_manager [Bluebook::ProcessManager, String] the process manager or its name
        # @return [Bluebook::Aggregate, nil] the starting aggregate with a bind of its own, or nil
        def saga_anchor(domain, process_manager)
          declared = declared_process_manager(domain, process_manager) or return nil
          starters = starting_aggregates(domain, declared.starts_on.to_s)
          return nil unless starters.size == 1 && bound_on_its_own?(home_of(domain, starters.first), starters.first)

          starters.first
        end

        # The bluebook that declares an aggregate: the domain's own when it does, else the loaded
        # one that does.
        #
        # @param domain [String, Symbol] the domain asking
        # @param aggregate [Bluebook::Aggregate] the aggregate
        # @return [String] the declaring bluebook's name; the domain's when none is found
        def home_of(domain, aggregate)
          candidates = [bluebook(domain), *bluebooks.values].compact
          candidates.find { |candidate| candidate.aggregates.include?(aggregate) }&.name || domain.to_s
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

        # The aggregates that emit an event: the domain's own, else those of the other loaded
        # bluebooks, since a process manager hears an event by its name from any of them.
        def starting_aggregates(domain, event_name)
          return [] if event_name.empty?

          own = emitters(bluebook(domain), event_name)
          own.empty? ? bluebooks.each_value.flat_map { |candidate| emitters(candidate, event_name) } : own
        end

        def emitters(declaring, event_name)
          Array(declaring&.aggregates).select do |aggregate|
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
