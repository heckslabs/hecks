require "json"
require "fileutils"
require_relative "heki/snapshot"
require_relative "heki/journal"
require_relative "heki/saga_store"
require_relative "../../ports/persistence/append_only"
require_relative "../../ports/query/in_memory"
require_relative "in_memory_ordering"
require_relative "../../runtime/instance"

module Hecks
  module Adapters
    # The file-backed store: a compressed snapshot (heki/snapshot.rb)
    # plus an append-only journal beside it (heki/journal.rb). What stays
    # here is the repository surface — find/all/save/delete, and the
    # entry append/project pair the persistence port drives.
    class Heki
      include Snapshot
      include Journal

      MAGIC = "HEKI".freeze
      HEADER_BYTES = 8

      class Malformed < StandardError; end

      attr_reader :aggregate, :path, :events

      # @param aggregate [Bluebook::Aggregate] the aggregate this store persists
      # @param settings [Hash] adapter settings; `dir:`/`"dir"` (a storage directory, `"data"`
      #   by default) and `domain:`/`"domain"` (the saga-persistence scope, defaulting to
      #   `aggregate.name`) are read
      # @param root [String, nil] the directory `settings[:dir]` resolves relative to when it
      #   is not absolute; defaults to the process's current working directory
      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate
        @path      = resolve_path(settings, root)
        @journal_path = "#{@path}.journal"
        @events    = []
        # The optional saga-persistence capability's own scoping (§2/§4)
        # — falls back to the aggregate's own name for a directly-
        # instantiated adapter (specs), same fallback shape Postgres's
        # own @domain already uses.
        @domain    = (
          if settings.key?(:domain)
            settings[:domain]
          elsif settings.key?("domain")
            settings["domain"]
          else
            aggregate.name
          end
        ).to_s

        FileUtils.mkdir_p(File.dirname(@path))
      end

      # Reads one record's current projected state.
      #
      # @param id [String, Object] the record's identity, compared as `id.to_s`
      # @return [Runtime::Instance, nil] the stored record, or nil when no record has that id
      def find(id)
        record = store[id.to_s]
        return nil unless record

        instance(id.to_s, record)
      end

      # Lists every record currently projected, sorted by id then reordered as requested.
      #
      # @param order_by [String, Symbol, nil] an attribute name to sort by; nil keeps id order
      # @param direction [Symbol] `:asc` or `:desc`
      # @return [Array<Runtime::Instance>] the stored records; `[]` when there are none
      def all(order_by: nil, direction: :asc)
        records = store.sort_by { |id, _| id }.map { |id, record| instance(id, record) }
        InMemoryOrdering.ordered(records, aggregate: @aggregate, order_by: order_by, direction: direction)
      end

      # Counts the records currently projected.
      #
      # @return [Integer] number of stored records, not of journal entries
      def count = store.size

      # Answers a declared query specification against the projected records.
      #
      # `registry: context[:registry]` — Memory's own `query` already
      # threads this through; Heki's own never did, which made
      # `none_in_state?` (Ports::Query::InMemory) unconditionally
      # return `true` (its own graceful "no registry, no way to look
      # the target up" default) for every `none_in_state` where-clause
      # against a Heki-backed aggregate — silently excluding nothing,
      # always, no matter the actual target state.
      #
      # @param specification [QuerySpecification::Common::Options,
      #   Bluebook::Behaviour::ReadModel::FilteredOptions] the declared query specification
      # @param args [Hash{Symbol => Object}] bound values for the specification's placeholders
      # @param context [Hash{Symbol => Object}] call context; `:registry` is read and passed
      #   through for registry-aware comparisons
      # @return [Array<Runtime::Instance>] the matching records, ordered and paged
      def query(specification, args = {}, context: {})
        Ports::Query::InMemory.execute(all, specification, args, registry: context[:registry])
      end

      # Writes one entry to the durable journal, before any projection of it.
      #
      # @param entry [Persistence::Entry] the save or delete to journal
      # @return [Persistence::Entry] `entry`, unchanged
      def append(entry)
        @entry_mirrors = entry.mirrors
        append_entry(entry.operation, entry.id, entry.state)
        entry
      ensure
        @entry_mirrors = nil
      end

      # Applies one journaled entry to the current-state snapshot.
      #
      # Reads fresh rather than trusting the memoized `store` — under
      # `with_lock`, another process may have projected a snapshot since
      # this one last read it, and mutating *its* stale copy would
      # overwrite that write on disk rather than layer on top of it.
      #
      # On a delete, though, the record `current.delete` finds is already
      # gone: every caller (`#delete` above, `AppendOnly#delete`) appends
      # before it projects, so the fresh read above has already replayed
      # this very entry off the journal. What the memoized `store` last
      # held — from before this call — is read up front, for the return
      # value only; it plays no part in what gets written.
      #
      # @param entry [Persistence::Entry] the save or delete to materialize
      # @return [Runtime::Instance, nil] on a save, the newly stored record; on a delete, the
      #   removed record, or nil when no record had that id
      def project(entry)
        removed = entry.delete? ? store[entry.id] : nil
        current = read
        if entry.save?
          current[entry.id] = Ports::Persistence::StateCodec.encode(@aggregate, entry.state)
          projected = Runtime::Instance.new(aggregate: @aggregate, id: entry.id, state: entry.state)
        else
          current.delete(entry.id)
          projected = removed && instance(entry.id, removed)
        end
        write(current)
        @store = current
        projected
      end

      # Journals and projects an instance's state under the file lock.
      #
      # @param instance [Runtime::Instance] the record to persist
      # @return [Runtime::Instance] `instance`, unchanged
      def save(instance)
        entry = Ports::Persistence::Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup)
        with_lock do
          append(entry)
          project(entry)
        end
        instance
      end

      # Journals and projects the removal of one record, if it exists, under the file lock.
      #
      # @param id [String, Object] the record's identity, compared as `id.to_s`
      # @return [Boolean] true when a record was found and deleted, false when there was none
      #   and nothing was journaled
      def delete(id)
        return false unless find(id)

        entry = Ports::Persistence::Entry.new(operation: "delete", id: id.to_s, state: nil)
        with_lock do
          append(entry)
          project(entry)
        end
        true
      end

      # Records one emitted event in this adapter's in-memory event log.
      #
      # @param event [Runtime::Event] the event to record
      # @return [Array<Runtime::Event>] the adapter's in-memory event log, including `event`
      def record_event(event) = @events << event

      # ── the optional saga-persistence capability (§2) — Heki's own
      # shape (a sibling snapshot+journal file pair, `SagaStore`,
      # heki/saga_store.rb) rather than a table in a store this adapter
      # doesn't have.
      #
      # @param process_manager [String, Symbol] the process manager's name, compared as
      #   `.to_s`
      # @param correlation [String, Symbol, Object] the instance's correlation value, compared
      #   as `.to_s`
      # @param state [String, Symbol] the saga's current state name, compared as `.to_s`
      # @param memory [Hash] the saga's working memory to persist
      # @param completed_compensations [Array] the ledger of completed compensable legs;
      #   `[]` when none
      # @return [Hash{String => Hash}] `SagaStore`'s internal records Hash after the write;
      #   callers ignore it
      def save_saga(process_manager:, correlation:, state:, memory:, completed_compensations: [])
        saga_store.save_saga(@domain, process_manager.to_s, correlation.to_s, state.to_s, memory, completed_compensations)
      end

      # Removes a finished saga instance's checkpoint; a missing one is not an error.
      #
      # @param process_manager [String, Symbol] the process manager's name, compared as
      #   `.to_s`
      # @param correlation [String, Symbol, Object] the instance's correlation value, compared
      #   as `.to_s`
      # @return [Hash{String => Hash}] `SagaStore`'s internal records Hash after the delete;
      #   callers ignore it
      def delete_saga(process_manager:, correlation:)
        saga_store.delete_saga(@domain, process_manager.to_s, correlation.to_s)
      end

      # Yields every checkpointed saga instance of this domain, for `Registry
      # #rehydrate_sagas!` to restore at boot.
      #
      # @yieldparam process_manager [String] the process manager's name
      # @yieldparam correlation [String] the instance's correlation value
      # @yieldparam state [String] the saga's state name
      # @yieldparam memory [Hash{Symbol => Object}] the saga's memory, Symbol keys at every
      #   depth
      # @yieldparam completed_compensations [Array] the completed-compensation ledger, `[]`
      #   when none was recorded
      # @return [Enumerator, Hash{String => Hash}] an enumerator over the same five values
      #   when no block is given; otherwise `SagaStore`'s internal records Hash
      def each_saga(&) = saga_store.each_saga(@domain, &)

      private

      def saga_store
        @saga_store ||= SagaStore.new(File.dirname(@path))
      end

      # `record` is the snapshot/journal's own string-keyed JSON — decoded
      # deep through the state codec, never symbolized one level by hand.
      def instance(id, record)
        Runtime::Instance.new(
          aggregate: @aggregate,
          id:        id,
          state:     Ports::Persistence::StateCodec.decode(@aggregate, record)
        )
      end

      def store
        @store ||= read
      end

      def read
        snapshot = read_snapshot
        replay_journal(snapshot)
      end

      # `dir: :default` — a bare Symbol, the framework's own convention
      # for "a declared value that resolves by convention, never a silent
      # fallback" — would otherwise crash `File.join` outright
      # (`TypeError: no implicit conversion of Symbol into String`):
      # `resolve_path` only ever checked for a missing `dir` setting,
      # never a Symbol one. Treated the same as no setting at all — falls
      # back to the existing "data" default, not a new special case.
      def resolve_path(settings, root)
        declared =
          if settings.key?(:dir)
            settings[:dir]
          elsif settings.key?("dir")
            settings["dir"]
          else
            "data"
          end
        declared = "data" if declared == :default
        dir      = declared.start_with?("/") ? declared : File.join(root || Dir.pwd, declared)

        File.join(dir, "#{@aggregate.storage_name}.heki")
      end
    end
  end
end
