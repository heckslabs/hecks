require_relative "../../runtime/registry"
require_relative "execution"

module Hecks
  module Ports
    module Persistence
      # `mirrors` is durable replication intent.  It is part of the same
      # append as the authoritative state, never a second outbox store.
      #
      # `sequence` is the journal position an adapter assigned this entry
      # (set by `append` on a live write, or by `entries`/`entries_since` on
      # a replayed one); nil for an adapter that assigns none. It rides
      # along so `project` can advance a checkpoint without a second lookup.
      Entry = Struct.new(:operation, :id, :state, :mirrors, :sequence, keyword_init: true) do
        # Tells a projecting adapter that this entry writes a record.
        #
        # @return [Boolean] true when `operation` is the String `"save"`
        def save? = operation == "save"

        # Tells a projecting adapter that this entry removes a record.
        #
        # @return [Boolean] true when `operation` is the String `"delete"`
        def delete? = operation == "delete"
      end

      # Makes append-before-projection a port invariant: adapters keep their own durable
      # format, but must accept the same entry stream and materialize state from it.
      class AppendOnly
        attr_reader :adapter

        # Names the aggregate this repository stores, as the wrapped adapter holds it.
        #
        # @return [Bluebook::Aggregate] the aggregate the adapter was built for
        def aggregate = @adapter.aggregate

        # @param adapter [Object] a driven persistence adapter; it must respond to `append`,
        #   `project` and `entries`
        # @raise [Runtime::WiringError] if the adapter lacks any of those three methods
        def initialize(adapter)
          @adapter = adapter
          required = %i[append project entries]
          missing = required.reject { |method| adapter.respond_to?(method) }
          unless missing.empty?
            raise Runtime::WiringError,
                  "#{adapter.class} does not implement append-only persistence: #{missing.join(', ')}"
          end
        end

        # Reads one record's current projected state from the adapter.
        #
        # @param id [String, Object] the record's identity; adapters compare it as `id.to_s`
        # @return [Runtime::Instance, nil] the stored record, or nil when no record has that id
        def find(id) = @adapter.find(id)

        # Lists every record the adapter currently projects, forwarding the keywords untouched.
        #
        # The shipped adapters accept `order_by:` (an attribute name, default nil for id or
        # insertion order) and `direction:` (`:asc` or `:desc`).
        #
        # @return [Array<Runtime::Instance>] the stored records; `[]` when there are none
        # @raise [Runtime::WiringError] from a SQL adapter when `order_by:` names no attribute
        #   of the aggregate
        def all(**) = @adapter.all(**)

        # Counts the records the adapter currently projects.
        #
        # @return [Integer] number of stored records, not of journal entries
        def count = @adapter.count

        # Reads the adapter's whole journal, oldest entry first.
        #
        # @return [Array<Persistence::Entry>] every appended entry with decoded state; `[]` for
        #   an empty journal or a `RemoteRuntime` adapter
        # @raise [Runtime::WiringError] if a guarded adapter answers an entry whose state is
        #   undecoded (`CodecBoundary.check_entries!`)
        def entries = @adapter.entries

        # Lists the optional persistence behaviours the adapter advertises.
        #
        # @return [Array<Symbol>] frozen capability names such as `:atomic_put`,
        #   `:optimistic_concurrency` or `:cross_process_lock`; `[]` when the adapter declares
        #   no `persistence_capabilities`
        def capabilities
          return [] unless @adapter.respond_to?(:persistence_capabilities)

          Array(@adapter.persistence_capabilities).map(&:to_sym).freeze
        end

        # Clears the adapter's stored records and journal so a kept runtime starts clean.
        #
        # @return [Object] whatever the adapter's `reset!` returns; every shipped adapter
        #   returns itself
        # @raise [Runtime::WiringError] if the adapter has no `reset!`, or (PostgresEra) if row
        #   level security silently matched none of the journal rows
        def reset!
          raise Runtime::WiringError, "append-only adapter cannot reset" unless @adapter.respond_to?(:reset!)

          @adapter.reset!
        end

        # Reads the events the adapter has durably recorded.
        #
        # Written as an `if` guard, not a trailing modifier, which would evaluate against
        # `@adapter` before `initialize` runs and silently skip defining the method.
        #
        # @return [Array<Runtime::Event>, nil] recorded events, oldest first; nil when the
        #   adapter keeps no event log
        def events
          @adapter.events if @adapter.respond_to?(:events)
        end

        # Replays unprojected journal entries through `project` to rebuild the projected
        # records.
        #
        # An append is durable before a projection is attempted. Replaying the
        # log restores a snapshot/table after a crash in that small window.
        # An adapter that keeps its projected table in the same transaction
        # as its journal append (Postgres, Sqlite) never actually falls
        # behind it, so it tracks how far it has already replayed
        # (`checkpoint`) and this only re-walks entries past that point
        # (`entries_since`) — bounded by activity since the last boot, not
        # total history. An adapter without that pair (Memory, Heki, D1,
        # PostgresEra, RemoteRuntime) is unaffected: it still replays every
        # entry, exactly as before.
        #
        # @return [Persistence::AppendOnly] self, so a factory can build and recover in one
        #   expression
        def recover!
          if @adapter.respond_to?(:checkpoint) && @adapter.respond_to?(:entries_since)
            @adapter.entries_since(@adapter.checkpoint).each { |entry| project(entry) }
          else
            entries.each { |entry| project(entry) }
          end
          self
        end

        # Writes one entry to the adapter's durable journal, before any projection of it.
        #
        # @param entry [Persistence::Entry] the save or delete to journal
        # @return [Persistence::Entry] the entry as the adapter returns it; every shipped
        #   adapter returns the entry it was given
        # @raise [Runtime::WiringError] from a `RemoteRuntime` adapter, which has no local
        #   journal, and from PostgresEra when its era is superseded
        def append(entry) = @adapter.append(entry)

        # Applies one journaled entry to the adapter's current-state store.
        #
        # @param entry [Persistence::Entry] the save or delete to materialize
        # @return [Object, nil] adapter-defined: Memory, Sqlite, Postgres and PostgresEra answer
        #   the saved `Runtime::Instance`; Heki and `SqliteProjection` answer the entry;
        #   a delete answers a driver result, the removed record, or nil
        # @raise [Runtime::WiringError] from a `RemoteRuntime` adapter, which projects nothing
        #   locally
        def project(entry) = @adapter.project(entry)

        # Journals an instance's state, projects it, and reports how the write landed.
        #
        # Returns an Outcome, not a bare Instance, so callers can check `:saved` vs `:stale`;
        # `expected_version:` only triggers CAS on an adapter declaring `:optimistic_concurrency`.
        #
        # @param instance [Runtime::Instance] the record to persist; its `state` is shallow
        #   copied into the entry
        # @param expected_version [Integer, nil] the version the instance was read at, or nil
        #   for an unconditional write
        # @return [Persistence::Outcome] status `:saved` or `:stale`; `instance` is the
        #   adapter's projected result on `:saved`, else the instance passed in
        # @raise [Runtime::WiringError] when the adapter's `append` or `project` refuses
        def save(instance, expected_version: nil)
          entry = Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup)
          append(entry)
          if expected_version && capabilities.include?(:optimistic_concurrency)
            saved = @adapter.project(entry, expected_version: expected_version)
            return Outcome.new(status: :stale, instance: instance) if saved.nil?

            return Outcome.new(status: :saved, instance: saved)
          end
          saved = @adapter.project(entry)
          Outcome.new(status: :saved, instance: saved || instance)
        end

        # Writes an instance through the adapter's own existence-check-and-write critical
        # section, so a create cannot race another writer.
        #
        # @param instance [Runtime::Instance] the record to persist
        # @param insert_only [Boolean] true to refuse replacing a record that already exists
        # @return [Persistence::Outcome] status `:inserted`, `:replaced`, or `:conflicted` when
        #   `insert_only` met an existing record and nothing was written; `instance` is always
        #   the instance passed in
        # @raise [Runtime::WiringError] if the adapter does not both advertise `:atomic_put`
        #   and implement it
        # @raise [ArgumentError] if the adapter answers a status outside `Outcome::STATUSES`
        def atomic_put(instance, insert_only: false)
          unless capabilities.include?(:atomic_put) && @adapter.respond_to?(:atomic_put)
            raise Runtime::WiringError,
                  "#{@adapter.class} advertises no atomic_put persistence capability"
          end

          entry = Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup)
          status = @adapter.atomic_put(entry, insert_only: insert_only)
          Outcome.new(status: status, instance: instance)
        end

        # Journals and projects the removal of one record, if it exists.
        #
        # @param id [String, Object] the record's identity; journaled as `id.to_s`
        # @return [Boolean] true when a record was found and deleted, false when there was
        #   none and nothing was journaled
        # @raise [Runtime::WiringError] when the adapter's `append` or `project` refuses
        def delete(id)
          return false unless find(id)

          entry = Entry.new(operation: "delete", id: id.to_s, state: nil)
          append(entry)
          project(entry)
          true
        end

        # Records one emitted event durably, when the adapter keeps an event log.
        #
        # Written as an `if` guard, not a trailing modifier — same reason as `events` above.
        #
        # @param event [Runtime::Event] the event to record
        # @return [Object, nil] adapter-defined write result (an Array for Memory, a driver
        #   result for the SQL adapters); nil when the adapter has no `record_event`
        def record_event(event)
          @adapter.record_event(event) if @adapter.respond_to?(:record_event)
        end

        # Runs the block inside the adapter's transaction, or plainly when it has none.
        #
        # One commit boundary for save + emit + outbox: an adapter with a real transaction
        # (Sqlite, Postgres) commits the row, journal entry, and outbox rows together or
        # not at all; Memory just yields, having nothing to roll back.
        #
        # @yield the writes to commit together; an exception raised inside rolls back an
        #   adapter-owned transaction and propagates
        # @return [Object] adapter-defined; the block's own value for every adapter without a
        #   `transaction` and for Memory
        def transaction(&)
          return @adapter.transaction(&) if @adapter.respond_to?(:transaction)

          yield
        end

        # Runs the block while holding the adapter's cross-process write lock.
        #
        # Only PostgresEra advertises `:cross_process_lock` (ADR 0036); the real dispatch
        # path checks `capabilities` first, so this `yield` fallback only guards a stray
        # direct call.
        #
        # @yield the dispatch to run with writers serialised
        # @return [Object] adapter-defined; the block's own value when the adapter has no
        #   `with_write_lock`
        def with_write_lock(&)
          return @adapter.with_write_lock(&) if @adapter.respond_to?(:with_write_lock)

          yield
        end

        # An adapter implements the whole outbox contract or none of it (see Runtime::Outbox).
        OUTBOX_METHODS = %i[outbox_enqueue outbox_claim outbox_settle outbox_rows].freeze

        # Reports whether the adapter implements the whole outbox contract; the answer is
        # memoized per repository.
        #
        # @return [Boolean] true only when the adapter responds to all four `OUTBOX_METHODS`
        def outbox?
          @outbox = OUTBOX_METHODS.all? { |method| @adapter.respond_to?(method) } if @outbox.nil?
          @outbox
        end

        # Stores pending outbox rows, skipping any whose `delivery_id` is already held.
        #
        # Call only after `outbox?` answers true; the other three outbox methods share that
        # precondition.
        #
        # @param rows [Array<Runtime::Outbox::Row>] the rows to enqueue, one per event and consumer
        # @return [Array<Runtime::Outbox::Row>] the rows actually stored, with `id` assigned;
        #   duplicates are dropped
        def outbox_enqueue(rows) = @adapter.outbox_enqueue(rows)

        # Moves one pending outbox row to `claimed` and counts the attempt.
        #
        # @param id [Integer] the row id assigned by `outbox_enqueue`
        # @return [Boolean] true when this call claimed the row; false when it is missing or
        #   not pending
        def outbox_claim(id) = @adapter.outbox_claim(id)

        # Records the final status of a claimed outbox row.
        #
        # @param id [Integer] the row id assigned by `outbox_enqueue`
        # @param status [String, Symbol] the settled status; `Runtime::Outbox` passes
        #   `"delivered"` or `"failed"`
        # @param error [String, nil] failure text, `"ErrorClass: message"`; nil on success
        # @return [Boolean] true when a row with that id was updated
        def outbox_settle(id, status:, error: nil) = @adapter.outbox_settle(id, status: status, error: error)

        # Lists this aggregate's outbox rows, oldest first.
        #
        # @param status [String, Symbol, nil] keep only rows with this status; nil for all rows
        # @return [Array<Runtime::Outbox::Row>] copies of the stored rows; `[]` when none match
        def outbox_rows(status: nil) = @adapter.outbox_rows(status: status)

        # Answers a read model from the adapter's own projected tables, when it can.
        #
        # @param domain [String, Symbol] name of the domain declaring the read model
        # @param model [Bluebook::ReadModel] the read model to answer
        # @param args [Hash{Symbol => Object}] the read model's arguments, including its
        #   reference argument
        # @param bluebook [Bluebook::Chapter, nil] the domain's bluebook, which the SQLite
        #   projection needs to find the included aggregates
        # @return [Array<Hash>, nil] a one-element Array holding the report Hash keyed by head
        #   name; nil when the adapter has no `query_read_model`
        # @raise [ArgumentError] if the adapter answers natively and `bluebook` is nil
        # @raise [Runtime::NotFound] if the referenced root record is not in the projection
        def query_read_model(domain, model, args, bluebook = nil)
          return unless @adapter.respond_to?(:query_read_model)

          @adapter.query_read_model(domain, model, args, bluebook)
        end
      end
    end
  end
end
