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

      # Resolves the snapshot/journal file paths under `root` and creates their directory;
      # the files themselves are created lazily on first write.
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate whose records this store holds
      # @param settings [Hash{Symbol, String => Object}] world settings for the binding:
      #   `dir` (directory the snapshot/journal live under, default `"data"`; `:default` is
      #   treated the same as absent) and `domain` (scopes saga rows, default the aggregate's
      #   name), each read under a Symbol or a String key
      # @param root [String, nil] directory a relative `dir` resolves against; nil means the
      #   process working directory
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

      # Looks up the current record for one aggregate identity, reading the snapshot and
      # journal on first call and caching them for later ones.
      #
      # @param id [String, Object] the aggregate identity, compared as `id.to_s`
      # @return [Runtime::Instance, nil] the decoded record, or nil when no record has that id
      # @raise [Malformed] if the snapshot or journal file is corrupt
      def find(id)
        record = store[id.to_s]
        return nil unless record

        instance(id.to_s, record)
      end

      # Lists every stored record, in id order unless an ordering attribute is given.
      #
      # @param order_by [String, Symbol, nil] attribute (or dotted value-object path) to sort
      #   by; nil orders by id alone
      # @param direction [Symbol, String] `:asc` or `:desc`
      # @return [Array<Runtime::Instance>] the decoded records, `[]` when the store is empty
      # @raise [Runtime::WiringError] if `order_by` names no attribute of the aggregate
      # @raise [Malformed] if the snapshot or journal file is corrupt
      def all(order_by: nil, direction: :asc)
        records = store.sort_by { |id, _| id }.map { |id, record| instance(id, record) }
        InMemoryOrdering.ordered(records, aggregate: @aggregate, order_by: order_by, direction: direction)
      end

      # Counts the records currently held, deleted ones excluded.
      #
      # @return [Integer] number of live records
      # @raise [Malformed] if the snapshot or journal file is corrupt
      def count = store.size

      # Answers a declared query by filtering, ordering and paging the held records in Ruby.
      #
      # `registry: context[:registry]` — passed through so `none_in_state?`
      # (Ports::Query::InMemory) can look another aggregate's target state up rather than
      # falling back to its own graceful "no registry, no way to look the target up" default,
      # which would silently exclude nothing for a `none_in_state` where-clause here.
      #
      # @param specification [QuerySpecification::Common::Options] the declared query
      # @param args [Hash{Symbol => Object}] values for the specification's symbolic operands
      # @param context [Hash] execution context; only `:registry` (a `Runtime::Registry` or
      #   nil) is read, for comparators that look up another aggregate
      # @return [Array<Runtime::Instance>] the matching records, `[]` when none match
      # @raise [Runtime::WiringError] if a where clause uses an operation no comparator handles
      # @raise [Malformed] if the snapshot or journal file is corrupt
      def query(specification, args = {}, context: {})
        Ports::Query::InMemory.execute(all, specification, args, registry: context[:registry])
      end

      # Appends one journal entry, fsynced before returning.
      #
      # @param entry [Ports::Persistence::Entry] the save or delete to journal
      # @return [Ports::Persistence::Entry] the same `entry`
      def append(entry)
        @entry_mirrors = entry.mirrors
        append_entry(entry.operation, entry.id, entry.state)
        entry
      ensure
        @entry_mirrors = nil
      end

      # Applies one journal entry to a freshly-read snapshot and writes it back to disk.
      #
      # Reads fresh rather than trusting the memoized `store` — under
      # `with_lock`, another process may have projected a snapshot since
      # this one last read it, and mutating *its* stale copy would
      # overwrite that write on disk rather than layer on top of it.
      #
      # @param entry [Ports::Persistence::Entry] the save or delete to materialize
      # @return [Ports::Persistence::Entry] the same `entry`
      # @raise [Malformed] if the snapshot or journal file is corrupt
      def project(entry)
        current = read
        if entry.save?
          current[entry.id] = Ports::Persistence::StateCodec.encode(@aggregate, entry.state)
        else
          current.delete(entry.id)
        end
        write(current)
        @store = current
        entry
      end

      # Journals and writes an instance's current state under the file lock, atomically
      # across processes.
      #
      # @param instance [Runtime::Instance] the instance to store
      # @return [Runtime::Instance] the same `instance`
      # @raise [Malformed] if the snapshot or journal file is corrupt
      def save(instance)
        entry = Ports::Persistence::Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup)
        with_lock do
          append(entry)
          project(entry)
        end
        instance
      end

      # Journals a delete and removes the record under the file lock, when one is held.
      #
      # @param id [String, Object] the aggregate identity, journalled as `id.to_s`
      # @return [Boolean] true when a record was held and is now removed; false when none was
      #   held, and nothing is journalled
      # @raise [Malformed] if the snapshot or journal file is corrupt
      def delete(id)
        return false unless find(id)

        entry = Ports::Persistence::Entry.new(operation: "delete", id: id.to_s, state: nil)
        with_lock do
          append(entry)
          project(entry)
        end
        true
      end

      # Appends an emitted event to the in-process event log.
      #
      # @param event [Runtime::Event] the emitted event
      # @return [Array<Runtime::Event>] the live event log, including `event`
      def record_event(event) = @events << event

      # Replaces one saga instance's checkpoint in the sibling saga snapshot/journal pair.
      #
      # ── the optional saga-persistence capability (§2) — Heki's own
      # shape (a sibling snapshot+journal file pair, `SagaStore`,
      # heki/saga_store.rb) rather than a table in a store this adapter
      # doesn't have.
      #
      # @param process_manager [String, Symbol] the process manager's name
      # @param correlation [String, Object] the instance's correlation value, stored as
      #   `correlation.to_s`
      # @param state [String, Symbol] the saga's current state name, stored as `state.to_s`
      # @param memory [Hash] the saga's memory
      # @param completed_compensations [Array] the ledger of completed compensable legs
      # @return [void]
      def save_saga(process_manager:, correlation:, state:, memory:, completed_compensations: [])
        saga_store.save_saga(@domain, process_manager.to_s, correlation.to_s, state.to_s, memory, completed_compensations)
      end

      # Removes a finished saga instance's checkpoint; a missing one is not an error.
      #
      # @param process_manager [String, Symbol] the process manager's name
      # @param correlation [String, Object] the instance's correlation value, matched as
      #   `correlation.to_s`
      # @return [void]
      def delete_saga(process_manager:, correlation:)
        saga_store.delete_saga(@domain, process_manager.to_s, correlation.to_s)
      end

      # Yields every checkpointed saga instance of this adapter's domain, for
      # `Registry#rehydrate_sagas!` to restore at boot.
      #
      # @yieldparam process_manager [String] the process manager's name
      # @yieldparam correlation [String] the instance's correlation value
      # @yieldparam state [String] the saga's state name
      # @yieldparam memory [Hash{Symbol => Object}] the saga's memory, Symbol keys one level deep
      # @yieldparam completed_compensations [Array] the completed-compensation ledger
      # @return [Enumerator, void] an enumerator over the same four values when no block is
      #   given
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
      # (`TypeError: no implicit conversion of Symbol into String`) if
      # this only checked for a missing `dir` setting and never a Symbol
      # one. Treated the same as no setting at all — falls
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
