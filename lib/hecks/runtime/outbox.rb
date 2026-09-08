require "json"
require "securerandom"
require "time"
require_relative "event"
require_relative "../naming"

module Hecks
  module Runtime
    # THE TRANSACTIONAL OUTBOX — the durable hand-off between "a command
    # committed" and "everything that was owed because it committed":
    # the policies that react to its events, the process managers that
    # advance on them, and (through a policy whose trigger is an
    # outbound port operation) the external effects those reactions
    # cause. `future-features.md` item 8, built.
    #
    # THE SHAPE. One row per (event, consumer). A consumer is a named
    # policy or process manager that would react to the event — resolved
    # at ENQUEUE time from the registry (`Fanout`), so the outbox records
    # WHO was owed what, not just that an event happened. Rows move
    # `pending → claimed → delivered | failed`:
    #
    #   pending    written in the SAME adapter transaction as the
    #              aggregate save (`Interpreting#run_dispatch_order`
    #              wraps `save` + `emit` + enqueue in `repository.
    #              transaction`), so a row exists iff the state change
    #              it reacts to committed — never one without the other.
    #   claimed    the relay is about to run this consumer. Set BEFORE
    #              the reaction (a policy's `reenter`, a saga leg's
    #              dispatch, an adapter call) runs.
    #   delivered  the consumer ran to completion — including the
    #              "ran and was refused" case, which is a delivered
    #              outcome the reaction log already records; the outbox
    #              tracks delivery, not the domain's answer.
    #   failed     the consumer raised a defect (non-refusal error).
    #
    # DELIVERY IS INLINE BY DEFAULT — the dispatcher drains the rows it
    # just wrote, in the same call, in the same order reactions always
    # ran (every policy row, then every saga row). Nothing about the
    # happy path is deferred or asynchronous; a caller still sees every
    # reaction settled when `dispatch` returns. What changes is the
    # crash window: a process that dies between commit and reaction
    # used to lose the reaction silently. Now the row survives, and
    # `Relay#redrive!` — run at boot by `Loader.run_boot_gates!` —
    # finds it.
    #
    # WHAT REDRIVE DOES, AND DELIBERATELY DOESN'T. A `pending` row is
    # REDRIVEN: its consumer provably never started (claiming is the
    # first thing delivery does), so running it now is exactly-once by
    # construction. A `claimed` row is NOT auto-redriven: the consumer
    # started and the crash hid its outcome — the same reasoning
    # `saga_pending_dispatch.rb` gives (a stalled transfer is a better
    # defect than a double-credited one). It is surfaced loudly
    # (`warn`, and a `stalled: true` entry in `Relay#log`) and left for
    # `Relay#redrive!(claimed: true)` — an explicit operator decision,
    # never a boot-time default. `delivery_id` (event uid + consumer) is
    # UNIQUE per store, so a re-enqueue of the same fact to the same
    # consumer is a no-op rather than a second row.
    #
    # WHICH ADAPTERS. Memory (in-process rows — visible to specs,
    # gone with the process, exactly like everything else Memory holds),
    # Sqlite and Postgres (a `hecks_outbox` table in the aggregate's own
    # database — the only way the enqueue can share the save's
    # transaction). An adapter without the contract (`outbox_enqueue`/
    # `outbox_claim`/`outbox_settle`/`outbox_rows`) gets today's
    # behaviour unchanged — reactions run directly, nothing durable —
    # and `Registry::Verification#warn_undurable_outbox!` says so at
    # boot when the domain declares anything that would have needed it.
    module Outbox
      STATUSES = %w[pending claimed delivered failed].freeze

      Row = Struct.new(:id, :delivery_id, :event_uid, :aggregate, :domain, :kind, :consumer, :event,
                       :status, :attempts, :error, keyword_init: true) do
        def pending?   = status == "pending"
        def claimed?   = status == "claimed"
        def delivered? = status == "delivered"
        def failed?    = status == "failed"

        # Wire-shaped — what an adapter persists. `event` is the event's
        # own `to_h` plus correlation; `Row.event_from` reverses it.
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

      # WHO IS OWED WHAT — the same selection `PolicyInterpreter#policies_for`
      # and `SagaInterpreter#advance` make at delivery time, made once at
      # enqueue time so the row names its consumer. Policy rows first,
      # then saga rows, event order preserved within each: exactly the
      # order `Dispatcher#dispatch` always ran them in.
      module Fanout
        module_function

        # ONE UID PER EVENT for this enqueue — the Event struct is
        # frozen after `emit!`, so the uid lives on the rows rather than
        # on it (and stays off `Event#to_h`, whose shape the golden and
        # parity specs pin). Policy and saga rows for the same event
        # share it, which is what makes `delivery_id` mean "this fact,
        # this consumer".
        def rows_for(registry, events, domain)
          uids = events.to_h { |event| [event, SecureRandom.uuid] }
          policy_rows = events.flat_map { |event| policies(registry, event, domain, uids[event]) }
          saga_rows   = events.flat_map { |event| sagas(registry, event, domain, uids[event]) }
          policy_rows + saga_rows
        end

        def policies(registry, event, domain, uid)
          emitting = Naming.demodulise(event.aggregate)
          registry.bluebooks.each_value.flat_map do |bluebook|
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

        # An "effect" is a reaction whose trigger is an outbound port
        # operation — the row is the durable record that an external
        # call was owed, claimed right before the adapter is asked and
        # settled right after. Everything else is a plain "reaction".
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

      # THE RELAY — one per `Dispatcher`. Enqueues into a repository's
      # store, drains rows inline, and redrives what a previous process
      # left behind.
      class Relay
        attr_reader :registry, :log

        # NOT `saga_log`/`reaction_log` — those are ported byte-for-byte
        # by the Rust kernel (`spec/rust_conformance_spec.rb`); this is
        # an additive, Ruby-only log, the same rule `saga_dispatch_log`
        # and `policy_dispatch_log` already follow.
        def initialize(registry)
          @registry = registry
          @log      = []
        end

        # A Dispatcher hands over the interpreters a consumer runs
        # through (`Dispatcher#initialize`). Until then this relay can
        # enqueue (that needs only the registry) but not deliver — and
        # nothing can dispatch without a dispatcher, so nothing asks it
        # to. The registry holds ONE relay for its lifetime; a second
        # dispatcher fronting the same registry re-attaches, which is
        # fine because both dispatchers share every log and store.
        def attach(policies:, sagas:)
          @policies = policies
          @sagas    = sagas
          self
        end

        def attached? = !@policies.nil?

        # Called INSIDE the save transaction by `Interpreting` for the
        # command/entity paths, and outside one by `Dispatcher` for port
        # operations (which save nothing, so there is no transaction to
        # share). Returns the rows as stored (ids assigned), or nil when
        # the repository has no outbox — the dispatcher then reacts
        # directly, exactly as before.
        def enqueue(repository, events, domain)
          return nil unless repository.outbox?
          return [] if events.empty?

          rows = Fanout.rows_for(@registry, events, domain)
          rows.each { |row| row.aggregate = repository.aggregate.storage_name }
          repository.outbox_enqueue(rows)
        end

        # Drain the rows a dispatch just committed. `rows` nil means "no
        # outbox here" — react directly, the pre-outbox path.
        def deliver(rows, events, domain, repository)
          if rows.nil?
            # Two passes on purpose — every policy before any saga, the
            # order `Dispatcher#dispatch` always ran them in (and the
            # order `Fanout.rows_for` reproduces for the outbox path).
            events.each { |event| @policies.react(event, domain) }
            events.each { |event| @sagas.advance(event, domain) }
            return
          end

          rows.each { |row| deliver_row(row, repository) }
        end

        # One row: claim, run its consumer, settle. A claim that fails
        # means another relay (or this one, re-entrantly) already has it.
        def deliver_row(row, repository)
          return false unless repository.outbox_claim(row.id)

          row.status = "claimed"
          begin
            run_consumer(row)
            repository.outbox_settle(row.id, status: "delivered")
            row.status = "delivered"
            true
          rescue StandardError => e
            # A DOMAIN_REFUSAL never reaches here — PolicyInterpreter and
            # SagaInterpreter both rescue it as a recorded, undelivered
            # reaction. Anything that does reach here is a defect in the
            # relay's own path (a consumer that no longer exists, an
            # adapter that raised outside the interpreters' own rescue).
            repository.outbox_settle(row.id, status: "failed", error: "#{e.class}: #{e.message}")
            row.status = "failed"
            row.error  = "#{e.class}: #{e.message}"
            @log << { outbox: row.delivery_id, consumer: row.consumer, delivered: false, defect: true,
                      reason: row.error }
            false
          end
        end

        # Every row in every bound store, newest last. `status:` narrows.
        def rows(status: nil)
          stores.flat_map { |repository| repository.outbox_rows(status: status) }
        end

        # BOOT-TIME RECONCILIATION. Redrives `pending` rows (never
        # claimed — safe by construction); surfaces `claimed` rows and
        # redrives them ONLY when told to (`claimed: true`).
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

        # Every repository the registry can resolve, one per (domain,
        # aggregate), keeping only those with an outbox. Bluebooks, not
        # hecksagons: a domain with no hecksagon at all is bound to the
        # default adapter (Memory), which has one. An aggregate a
        # hecksagon deliberately left unbound raises WiringError from
        # `repository` and is skipped — the same "forgotten decision"
        # rule dispatch itself applies, not softened here.
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
