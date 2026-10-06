require "securerandom"
require_relative "../../naming"

module Hecks
  module Runtime
    module Outbox
      # Resolves each event's consumers once, at enqueue time, in the same
      # order a direct dispatch would react to them (policies then sagas).
      module Fanout
        module_function

        # One UID per event, kept off `Event#to_h` (parity/golden specs pin
        # its shape) — policy and saga rows for the same event share it, which
        # is what makes `delivery_id` mean "this fact, this consumer".
        def rows_for(registry, events, domain)
          uids = events.to_h { |event| [event, SecureRandom.uuid] }
          events.flat_map do |event|
            policies(registry, event, domain, uids[event]) + sagas(registry, event, domain, uids[event])
          end
        end

        def policies(registry, event, domain, uid)
          emitting = Naming.demodulise(event.aggregate)
          Outbox.bluebooks_home_first(registry, domain).flat_map do |bluebook|
            bluebook.policies.filter_map do |policy|
              next unless reacts?(policy, event, emitting)

              consumer = "policy:#{bluebook.name}::#{policy.name}"
              row_for(event, domain, uid, consumer, kind_for(registry, policy, bluebook.name))
            end
          end
        end

        # Whether the policy answers this event, from the aggregate that emitted it.
        def reacts?(policy, event, emitting)
          policy.event_name == event.name && (policy.event_qualifier.nil? || policy.event_qualifier == emitting)
        end

        # A saga only ever reacts within its own domain.
        def sagas(registry, event, domain, uid)
          bluebook = registry.bluebook(domain)
          return [] unless bluebook

          bluebook.process_managers.select { |process_manager| listens?(process_manager, event) }.map do |process_manager|
            row_for(event, domain, uid, "saga:#{bluebook.name}::#{process_manager.name}", "reaction")
          end
        end

        def row_for(event, domain, uid, consumer, kind)
          Outbox::Row.new(delivery_id: "#{uid}/#{consumer}", event_uid: uid, domain: domain, kind: kind,
                          consumer: consumer, event: Outbox.serialize_event(event), status: "pending", attempts: 0)
        end

        def listens?(process_manager, event)
          process_manager.starts_on == event.name || process_manager.ends_on == event.name ||
            !process_manager.handler_for(event.name).nil?
        end

        # An "effect" is a reaction whose trigger resolves to an outbound port
        # operation, claimed right before the adapter call and settled right
        # after; everything else is a plain "reaction".
        def kind_for(registry, policy, home_domain)
          target = "#{policy.target_domain || home_domain}::#{policy.trigger_command}"
          parsed = Naming.split_verb(target)
          return "reaction" unless parsed

          outbound_operation?(registry, parsed) ? "effect" : "reaction"
        end

        def outbound_operation?(registry, parsed)
          target_domain, aggregate_name, path = parsed
          head, rest = path.to_s.split(".", 2)
          return false unless rest

          aggregate = registry.bluebook(target_domain)&.aggregate(aggregate_name)
          port = aggregate&.port(head)
          port&.operation(rest)&.outbound?
        end
      end
    end
  end
end
