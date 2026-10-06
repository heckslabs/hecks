require_relative "consumer_runner"

module Hecks
  module Runtime
    module Outbox
      # One per Dispatcher: enqueues rows into a repository's outbox, drains
      # them inline, and redrives whatever a crash left behind.
      class Relay
        include ConsumerRunner

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
          settle_delivery(row, repository)
        end

        # Every row across every bound store, newest last.
        def rows(status: nil)
          stores.flat_map { |repository| repository.outbox_rows(status: status) }
        end

        # `pending` rows are always safe to redrive (never claimed yet).
        # `claimed` rows are only surfaced — redelivering a maybe-already-run
        # consumer needs an explicit `claimed: true`.
        def redrive!(claimed: false)
          stores.flat_map { |repository| redrive_store(repository, claimed) }
        end

        private

        def settle_delivery(row, repository)
          run_consumer(row)
          repository.outbox_settle(row.id, status: "delivered")
          row.status = "delivered"
          true
        rescue StandardError => e
          settle_failed(row, repository, e)
          false
        end

        # A DOMAIN_REFUSAL never reaches here (PolicyInterpreter and
        # SagaInterpreter both rescue it as a recorded, undelivered
        # reaction) — anything here is a defect in the relay's own path.
        def settle_failed(row, repository, error)
          repository.outbox_settle(row.id, status: "failed", error: "#{error.class}: #{error.message}")
          row.status = "failed"
          row.error  = "#{error.class}: #{error.message}"
          @log << { outbox: row.delivery_id, consumer: row.consumer, delivered: false, defect: true,
                    reason: row.error }
        end

        # The rows of one store that redrove: its pending rows first, then its claimed ones.
        def redrive_store(repository, claimed)
          redriven = repository.outbox_rows(status: "pending").select { |row| deliver_row(row, repository) }
          redriven + repository.outbox_rows(status: "claimed").select { |row| redrive_claimed?(row, repository, claimed) }
        end

        def redrive_claimed?(row, repository, claimed)
          unless claimed
            warn_stalled(row)
            return false
          end

          repository.outbox_settle(row.id, status: "pending")
          row.status = "pending"
          deliver_row(row, repository)
        end

        def warn_stalled(row)
          warn stalled_wording(row)
          @log << { outbox: row.delivery_id, consumer: row.consumer, kind: row.kind, stalled: true,
                    event: row.event[:name], aggregate: row.event[:aggregate], id: row.event[:id] }
        end

        def stalled_wording(row)
          "[hecks] outbox row #{row.delivery_id} (#{row.consumer} on #{row.event[:name]} for " \
            "#{row.event[:aggregate]}##{row.event[:id]}) was claimed before the last crash/restart and never " \
            "settled — its #{row.kind} may or may not have actually run. hecks does not auto-redrive a claimed " \
            "row (the outcome is unknown, and redelivering it could double the effect); inspect it and " \
            "redrive by hand with `runtime.outbox.redrive!(claimed: true)` once you know it is safe."
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
