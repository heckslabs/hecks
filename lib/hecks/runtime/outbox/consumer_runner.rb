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
          when "policy" then refusal_reason(written(run_policy(row, event, fqn, home, name)))
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

        # The records of a reaction that may be settled. One that found the store held before it
        # wrote anything is not settled: the relay puts its row back to pending.
        def written(records)
          unwritten = Array(records).find { |record| record[:unwritten] }
          raise HeldStore::Unwritten, unwritten[:reason].to_s if unwritten

          records
        end

        # The reason the domain refused a policy's reaction, nil when none was refused. A defect
        # is not a refusal, and neither is a reaction a held store stopped: each is said where it
        # happens and the row settles as delivered.
        def refusal_reason(records)
          refused = Array(records).find { |record| record[:delivered] == false && !record[:defect] && !record[:held] }
          refused && (refused[:reason].to_s.empty? ? "refused (no reason given)" : refused[:reason].to_s)
        end

        def run_saga(row, event, fqn, home, name)
          process_manager = @registry.bluebook(home)&.process_managers&.find { |candidate| candidate.name == name } ||
                            raise(WiringError,
                                  "outbox row #{row.delivery_id} names process_manager #{fqn}, which no bluebook declares")
          @sagas.advance(event, row.domain, only: process_manager, home: home)
          nil
        end
      end
    end
  end
end
