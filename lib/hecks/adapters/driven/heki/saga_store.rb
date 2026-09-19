require_relative "snapshot"
require_relative "journal"

module Hecks
  module Adapters
    class Heki
      # The optional saga-persistence capability (§2), Heki's own shape —
      # a sibling snapshot+journal file pair, built the exact same way an
      # aggregate's own persistence already is.
      #
      # ## Why it reuses Snapshot/Journal
      #
      # `Snapshot`/`Journal` (heki/snapshot.rb, heki/journal.rb) operate
      # generically on `@path`/`@journal_path`/`@entry_mirrors` and never
      # touch `@aggregate`, so this reuses them unchanged rather than
      # re-deriving the same binary framing and crash-recovery replay.
      #
      # ## Where it lives
      #
      # Reserved file name (`hecks_saga_instances.heki`, matching the
      # `hecks_`-prefix convention every other new saga table in this
      # work uses) avoids colliding with any real aggregate's own
      # `storage_name`. Lives in the same directory an aggregate's own
      # `.heki` file would (`File.dirname(@path)`, `Heki`'s own call
      # below) — which, since Heki's `resolve_path` has no per-domain
      # component at all, is typically shared across every domain
      # booted from the same `root`. `domain` is therefore carried
      # inside each record and filtered on read, the same reason
      # Postgres's own `hecks_saga_instances` keeps an explicit `domain`
      # column under schema isolation (§3).
      #
      # ## Record shape
      #
      # One flat records hash, keyed by a composite string (Heki's own
      # snapshot format is id-keyed, not tuple-keyed) — never exposed
      # outside this class; `each_saga` yields the five real fields a
      # caller actually wants, not the internal key shape.
      #
      # ## Durability
      #
      # Locked the same way an aggregate's own store is: `with_lock`
      # (`Snapshot`, shared) serializes each save/delete's read-modify-
      # write against `@path`'s own lock file — a saga gets exactly the
      # durability and concurrency-safety this adapter already gives its
      # aggregates, no better, no worse.
      class SagaStore
        include Snapshot
        include Journal

        # Resolves the saga snapshot/journal file paths under `dir`.
        #
        # @param dir [String] the directory an aggregate's own `.heki` file lives in
        def initialize(dir)
          @path         = File.join(dir, "hecks_saga_instances.heki")
          @journal_path = "#{@path}.journal"
          @entry_mirrors = nil
        end

        # Journals and writes one saga instance's checkpoint under the file lock, atomically
        # across processes.
        #
        # @param domain [String] the domain the saga belongs to, stored in the record and
        #   filtered on by `each_saga`
        # @param process_manager [String] the process manager's name
        # @param correlation [String] the instance's correlation value
        # @param state [String] the saga's current state name
        # @param memory [Hash] the saga's memory
        # @param completed_compensations [Array] the ledger of completed compensable legs
        # @return [void]
        def save_saga(domain, process_manager, correlation, state, memory, completed_compensations = [])
          key    = key_for(domain, process_manager, correlation)
          record = { "domain" => domain, "process_manager" => process_manager,
                     "correlation" => correlation, "state" => state, "memory" => memory,
                     "completed_compensations" => completed_compensations }

          with_lock do
            append_entry("save", key, record)
            current = replay_journal(read_snapshot)
            current[key] = record
            write(current)
            @store = current
          end
        end

        # Journals a delete and removes one saga instance's checkpoint under the file lock;
        # a missing one is not an error.
        #
        # @param domain [String] the domain the saga belongs to
        # @param process_manager [String] the process manager's name
        # @param correlation [String] the instance's correlation value
        # @return [void]
        def delete_saga(domain, process_manager, correlation)
          key = key_for(domain, process_manager, correlation)

          with_lock do
            append_entry("delete", key, nil)
            current = replay_journal(read_snapshot)
            current.delete(key)
            write(current)
            @store = current
          end
        end

        # Yields every checkpointed saga instance of one domain, for
        # `Registry#rehydrate_sagas!` to restore at boot.
        #
        # @param domain [String] only records with this stored `domain` are yielded
        # @yieldparam process_manager [String] the process manager's name
        # @yieldparam correlation [String] the instance's correlation value
        # @yieldparam state [String] the saga's state name
        # @yieldparam memory [Hash{Symbol => Object}] the saga's memory, Symbol keys one level deep
        # @yieldparam completed_compensations [Array] the completed-compensation ledger, `[]`
        #   when the record has none
        # @return [Enumerator, void] an enumerator over the same five values when no block is
        #   given
        # @raise [Malformed] if the snapshot or journal file is corrupt
        def each_saga(domain)
          return enum_for(:each_saga, domain) unless block_given?

          store.each_value do |record|
            next unless record["domain"] == domain

            yield record["process_manager"], record["correlation"], record["state"],
                  (record["memory"] || {}).transform_keys(&:to_sym),
                  record["completed_compensations"] || []
          end
        end

        private

        def store
          @store ||= replay_journal(read_snapshot)
        end

        # A plain space-joined key, not anything fancier — a correlation value is real
        # business data (an order id, a customer reference) and nothing
        # here should assume it never contains a space.
        def key_for(domain, process_manager, correlation) = [domain, process_manager, correlation].join(" ")
      end
    end
  end
end
