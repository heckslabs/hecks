require "json"
require "securerandom"
require "time"
require_relative "event"
require_relative "../naming"

module Hecks
  module Runtime
    # A durable outbox (ADR 0053): one row per (event, consumer), written in
    # the same transaction as the aggregate save so a reaction is never lost.
    module Outbox
      # pending -> claimed -> delivered | failed
      STATUSES = %w[pending claimed delivered failed].freeze

      Row = Struct.new(:id, :delivery_id, :event_uid, :aggregate, :domain, :kind, :consumer, :event,
                       :status, :attempts, :error, keyword_init: true) do
        def pending?   = status == "pending"
        def claimed?   = status == "claimed"
        def delivered? = status == "delivered"
        def failed?    = status == "failed"

        # Wire shape persisted by adapters; `Outbox.event_from` reverses it.
        def to_h
          { id: id, delivery_id: delivery_id, event_uid: event_uid, aggregate: aggregate, domain: domain,
            kind: kind, consumer: consumer, event: event, status: status, attempts: attempts, error: error }
        end

        def to_s = "#{consumer} ← #{event[:name]}(#{event[:aggregate]}##{event[:id]}) [#{status}]"
        def inspect = "#<Outbox::Row #{self}>"
      end

      module_function

      def serialize_event(event)
        event.to_h.merge(correlation: event.correlation)
      end

      # Emitting domain's own bluebook first, then load order (C10.2) — the
      # same order `PolicyInterpreter#policies_for` and `Fanout.policies` use.
      def bluebooks_home_first(registry, domain)
        home, others = registry.bluebooks.each_value.partition { |bluebook| bluebook.name == domain }
        home + others
      end

      def event_from(hash)
        hash = hash.transform_keys(&:to_sym)
        Event.new(
          name:        hash[:name],
          aggregate:   hash[:aggregate],
          id:          hash[:id],
          payload:     deep_symbolize(hash[:payload] || {}),
          occurred_at: hash[:occurred_at],
          correlation: hash[:correlation]
        ).emit!
      end

      def deep_symbolize(value)
        case value
        when Hash  then value.to_h { |k, v| [k.to_sym, deep_symbolize(v)] }
        when Array then value.map { |element| deep_symbolize(element) }
        else value
        end
      end

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
              next unless policy.event_name == event.name
              next unless policy.event_qualifier.nil? || policy.event_qualifier == emitting

              consumer = "policy:#{bluebook.name}::#{policy.name}"
              Row.new(delivery_id: "#{uid}/#{consumer}", event_uid: uid, domain: domain,
                      kind: kind_for(registry, policy, bluebook.name), consumer: consumer,
                      event: Outbox.serialize_event(event), status: "pending", attempts: 0)
            end
          end
        end

        # A saga only ever reacts within its own domain.
        def sagas(registry, event, domain, uid)
          bluebook = registry.bluebook(domain)
          return [] unless bluebook

          bluebook.process_managers.select { |process_manager| listens?(process_manager, event) }.map do |process_manager|
            consumer = "saga:#{bluebook.name}::#{process_manager.name}"
            Row.new(delivery_id: "#{uid}/#{consumer}", event_uid: uid, domain: domain, kind: "reaction",
                    consumer: consumer, event: Outbox.serialize_event(event), status: "pending", attempts: 0)
          end
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

          target_domain, aggregate_name, path = parsed
          head, rest = path.to_s.split(".", 2)
          return "reaction" unless rest

          aggregate = registry.bluebook(target_domain)&.aggregate(aggregate_name)
          port = aggregate&.port(head)
          port&.operation(rest)&.outbound? ? "effect" : "reaction"
        end
      end

      # One per Dispatcher: enqueues rows into a repository's outbox, drains
      # them inline, and redrives whatever a crash left behind.
      class Relay
        attr_reader :registry, :log

        # Additive and Ruby-only, unlike `saga_log`/`reaction_log`, which the
        # Rust kernel ports byte-for-byte (spec/rust_conformance_spec.rb).
        def initialize(registry)
          @registry = registry
          @log      = []
        end

        # Re-attaching (a second Dispatcher fronting the same registry) is
        # safe: both dispatchers share this relay's log and every store.
        def attach(policies:, sagas:)
          @policies = policies
          @sagas    = sagas
          self
        end

        def attached? = !@policies.nil?

        # Called inside the save transaction for command/entity paths, and
        # outside one for port operations (which save nothing). Returns nil
        # when the repository has no outbox — callers then react directly.
        def enqueue(repository, events, domain)
          return nil unless repository.outbox?
          return [] if events.empty?

          rows = Fanout.rows_for(@registry, events, domain)
          rows.each { |row| row.aggregate = repository.aggregate.storage_name }
          repository.outbox_enqueue(rows)
        end

        # `rows` nil means no outbox on this repository — react directly,
        # the pre-outbox path.
        def deliver(rows, events, domain, repository)
          if rows.nil?
            # Per event, in `emits` order — its policies, then its sagas
            # (C10.2, docs/semantics/bluebook-semantics.md).
            events.each do |event|
              @policies.react(event, domain)
              @sagas.advance(event, domain)
            end
            return
          end

          rows.each { |row| deliver_row(row, repository) }
        end

        # Claim, run the consumer, then settle. A failed claim means another
        # relay already has this row.
        def deliver_row(row, repository)
          return false unless repository.outbox_claim(row.id)

          row.status = "claimed"
          begin
            run_consumer(row)
            repository.outbox_settle(row.id, status: "delivered")
            row.status = "delivered"
            true
          rescue StandardError => e
            # A DOMAIN_REFUSAL never reaches here (PolicyInterpreter and
            # SagaInterpreter both rescue it as a recorded, undelivered
            # reaction) — anything here is a defect in the relay's own path.
            repository.outbox_settle(row.id, status: "failed", error: "#{e.class}: #{e.message}")
            row.status = "failed"
            row.error  = "#{e.class}: #{e.message}"
            @log << { outbox: row.delivery_id, consumer: row.consumer, delivered: false, defect: true,
                      reason: row.error }
            false
          end
        end

        # Every row across every bound store, newest last.
        def rows(status: nil)
          stores.flat_map { |repository| repository.outbox_rows(status: status) }
        end

        # `pending` rows are always safe to redrive (never claimed yet).
        # `claimed` rows are only surfaced — redelivering a maybe-already-run
        # consumer needs an explicit `claimed: true`.
        def redrive!(claimed: false)
          redriven = []
          stores.each do |repository|
            repository.outbox_rows(status: "pending").each do |row|
              redriven << row if deliver_row(row, repository)
            end
            repository.outbox_rows(status: "claimed").each do |row|
              if claimed
                repository.outbox_settle(row.id, status: "pending")
                row.status = "pending"
                redriven << row if deliver_row(row, repository)
              else
                warn_stalled(row)
              end
            end
          end
          redriven
        end

        private

        def run_consumer(row)
          raise WiringError, "outbox relay has no dispatcher attached — nothing can run #{row.consumer}" unless attached?

          event = Outbox.event_from(row.event)
          kind, fqn = row.consumer.split(":", 2)
          home, name = fqn.split("::", 2)
          case kind
          when "policy"
            policy = @registry.bluebook(home)&.policies&.find { |candidate| candidate.name == name } ||
                     raise(WiringError, "outbox row #{row.delivery_id} names policy #{fqn}, which no bluebook declares")
            @policies.react(event, row.domain, only: [policy, home])
          when "saga"
            process_manager = @registry.bluebook(home)&.process_managers&.find { |candidate| candidate.name == name } ||
                              raise(WiringError,
                                    "outbox row #{row.delivery_id} names process_manager #{fqn}, which no bluebook declares")
            @sagas.advance(event, row.domain, only: process_manager)
          else
            raise WiringError, "outbox row #{row.delivery_id} has an unknown consumer kind #{kind.inspect}"
          end
        end

        def warn_stalled(row)
          warn "[hecks] outbox row #{row.delivery_id} (#{row.consumer} on #{row.event[:name]} for " \
               "#{row.event[:aggregate]}##{row.event[:id]}) was claimed before the last crash/restart and never " \
               "settled — its #{row.kind} may or may not have actually run. hecks does not auto-redrive a claimed " \
               "row (the outcome is unknown, and redelivering it could double the effect); inspect it and " \
               "redrive by hand with `runtime.outbox.redrive!(claimed: true)` once you know it is safe."
          @log << { outbox: row.delivery_id, consumer: row.consumer, kind: row.kind, stalled: true,
                    event: row.event[:name], aggregate: row.event[:aggregate], id: row.event[:id] }
        end

        # Bluebooks, not hecksagons: a domain with no hecksagon is still
        # bound to the default Memory adapter. An aggregate a hecksagon left
        # unbound raises WiringError here and is skipped.
        def stores
          @registry.bluebooks.each_value.flat_map do |bluebook|
            bluebook.aggregates.filter_map do |aggregate|
              repository = @registry.repository(bluebook.name, aggregate)
              repository if repository.outbox?
            rescue WiringError
              nil
            end
          end
        end
      end
    end
  end
end
