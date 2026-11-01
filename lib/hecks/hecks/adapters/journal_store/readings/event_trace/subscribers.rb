# frozen_string_literal: true

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module EventTrace
          # Who listens to an event, read from the bluebooks alone: every policy (an `across` policy
          # and a `for_each` fan-out included, an `ask` as the verb the hecksagon resolved) and
          # every process manager that starts, ends or handles the event. The consumer name is the
          # one the outbox records, so a subscriber and its row meet on it.
          class Subscribers
            # @param registry [Runtime::Registry] a described registry
            def initialize(registry)
              @registry = registry
            end

            # @param name [String] the event's bare name
            # @param aggregate [String] the aggregate that emitted it, as the log records it
            # @return [Array<Hash>] one description per listener, the emitting domain's first
            def for_event(name, aggregate)
              emitting = Naming.demodulise(aggregate)
              domain = aggregate.to_s.split("::", 2).first
              Runtime::Outbox.bluebooks_home_first(@registry, domain).flat_map do |bluebook|
                policies(bluebook, name, emitting) + sagas(bluebook, name)
              end
            end

            # @return [Array<Hash>] every policy, with the event it listens to
            def policies_all
              @registry.bluebooks.values.flat_map { |bluebook| bluebook.policies.map { |p| describe(bluebook, p) } }
            end

            private

            def policies(bluebook, name, emitting)
              bluebook.policies.select { |policy| listens?(policy, name, emitting) }.map { |p| describe(bluebook, p) }
            end

            def listens?(policy, name, emitting)
              policy.event_name == name && (policy.event_qualifier.nil? || policy.event_qualifier == emitting)
            end

            def describe(bluebook, policy)
              { consumer: "policy:#{bluebook.name}::#{policy.name}", kind: "policy", on: policy.on_event.to_s,
                reaches: reaches(bluebook, policy), across: policy.target_domain&.to_s,
                where: present(policy.where), for_each: present(policy.for_each) }.compact
            end

            def present(text) = text.to_s.empty? ? nil : text.to_s

            def reaches(bluebook, policy)
              return policy.reaches if policy.trigger_command.to_s.empty?

              "#{policy.target_domain || bluebook.name}::#{policy.trigger_command}"
            end

            def sagas(bluebook, name)
              bluebook.process_managers.select { |pm| handles?(pm, name) }.map do |manager|
                { consumer: "saga:#{bluebook.name}::#{manager.name}", kind: "saga" }
              end
            end

            def handles?(manager, name)
              manager.starts_on == name || manager.ends_on == name || !manager.handler_for(name).nil?
            end
          end
        end
      end
    end
  end
end
