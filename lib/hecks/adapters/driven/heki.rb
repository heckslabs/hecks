require "json"
require "fileutils"
require_relative "heki/snapshot"
require_relative "heki/journal"
require_relative "heki/saga_store"
require_relative "heki/sagas"
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
      include Sagas

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
        @events = []
        # Saga scope; falls back to the aggregate's name for a directly built adapter.
        @domain = setting(settings, :domain, aggregate.name).to_s
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
      # The registry is passed through so `none_in_state` clauses can look up their target.
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
      # Reads fresh, not the memoized `store`: another process may have projected since,
      # and a stale copy would overwrite that write.
      #
      # On a delete the fresh read has already replayed the entry, so the returned record
      # comes from the memoized `store`, read up front.
      #
      # @param entry [Persistence::Entry] the save or delete to materialize
      # @return [Runtime::Instance, nil] on a save, the newly stored record; on a delete, the
      #   removed record, or nil when no record had that id
      def project(entry)
        removed = entry.delete? ? store[entry.id] : nil
        current = read
        projected = entry.save? ? apply_save(current, entry) : apply_delete(current, entry, removed)
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
      def delete(id) # rubocop:disable Naming/PredicateMethod -- the repository port's verb, answering whether a record existed
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

      private

      def apply_save(current, entry)
        current[entry.id] = Ports::Persistence::StateCodec.encode(@aggregate, entry.state)
        Runtime::Instance.new(aggregate: @aggregate, id: entry.id, state: entry.state)
      end

      def apply_delete(current, entry, removed)
        current.delete(entry.id)
        removed && instance(entry.id, removed)
      end

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

      # `dir: :default` means no setting; a Symbol would make `File.join` raise TypeError.
      def resolve_path(settings, root)
        declared = setting(settings, :dir, "data")
        declared = "data" if declared == :default
        dir      = declared.start_with?("/") ? declared : File.join(root || Dir.pwd, declared)

        File.join(dir, "#{@aggregate.storage_name}.heki")
      end

      # A setting read under its Symbol key, then its String key, then `default`.
      def setting(settings, key, default)
        return settings[key] if settings.key?(key)
        return settings[key.to_s] if settings.key?(key.to_s)

        default
      end
    end
  end
end
