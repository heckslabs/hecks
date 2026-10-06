require_relative "../errors"

module Hecks
  module Runtime
    module Outbox
      # Runs the consumer a row names: the policy or process manager that owes the reaction.
      # Mixed into {Relay}, which holds the registry and the interpreters it attached.
      module ConsumerRunner
        private

        def run_consumer(row)
          raise WiringError, "outbox relay has no dispatcher attached — nothing can run #{row.consumer}" unless attached?

          event = Outbox.event_from(row.event)
          kind, fqn = row.consumer.split(":", 2)
          home, name = fqn.split("::", 2)
          case kind
          when "policy" then run_policy(row, event, fqn, home, name)
          when "saga" then run_saga(row, event, fqn, home, name)
          else
            raise WiringError, "outbox row #{row.delivery_id} has an unknown consumer kind #{kind.inspect}"
          end
        end

        def run_policy(row, event, fqn, home, name)
          policy = @registry.bluebook(home)&.policies&.find { |candidate| candidate.name == name } ||
                   raise(WiringError, "outbox row #{row.delivery_id} names policy #{fqn}, which no bluebook declares")
          @policies.react(event, row.domain, only: [policy, home], event_uid: row.event_uid)
        end

        def run_saga(row, event, fqn, home, name)
          process_manager = @registry.bluebook(home)&.process_managers&.find { |candidate| candidate.name == name } ||
                            raise(WiringError,
                                  "outbox row #{row.delivery_id} names process_manager #{fqn}, which no bluebook declares")
          @sagas.advance(event, row.domain, only: process_manager)
        end
      end
    end
  end
end
