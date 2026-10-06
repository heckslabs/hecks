require_relative "snapshot"
require_relative "journal"

module Hecks
  module Adapters
    class Heki
      # Saga checkpoints in a sibling snapshot+journal file pair, keyed by
      # (domain, process manager, correlation).
      #
      # The file is shared by every domain booted from the same directory, so `domain`
      # is stored in each record and filtered on read.
      class SagaStore
        include Snapshot
        include Journal

        # @param dir [String] the directory to hold the saga snapshot+journal file pair,
        #   shared with the aggregate `.heki` files that already live there
        def initialize(dir)
          @path         = File.join(dir, "hecks_saga_instances.heki")
          @journal_path = "#{@path}.journal"
          @entry_mirrors = nil
        end

        # Upserts one saga instance's checkpoint, keyed by domain, process manager and
        # correlation, under the file lock.
        #
        # @param domain [String] the owning domain, carried in the record and filtered on read
        # @param process_manager [String] the process manager's name
        # @param correlation [String] the instance's correlation value
        # @param checkpoint [Hash{String => Object}] the saga's `"state"` (name), `"memory"`
        #   (working memory) and `"completed_compensations"` (compensable legs; `[]` when none)
        # @return [Hash{String => Hash}] the full records Hash after the write; callers ignore it
        def save_saga(domain, process_manager, correlation, checkpoint)
          key    = key_for(domain, process_manager, correlation)
          record = { "domain" => domain, "process_manager" => process_manager,
                     "correlation" => correlation }.merge(checkpoint)

          with_lock do
            append_entry("save", key, record)
            current = replay_journal(read_snapshot)
            current[key] = record
            write(current)
            @store = current
          end
        end

        # Removes a finished saga instance's checkpoint, if present, under the file lock; a
        # missing one is not an error.
        #
        # @param domain [String] the owning domain
        # @param process_manager [String] the process manager's name
        # @param correlation [String] the instance's correlation value
        # @return [Hash{String => Hash}] the store's full internal records Hash after the
        #   delete; callers ignore it
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

        # Yields every checkpointed saga instance of `domain`, for boot-time rehydration.
        #
        # @param domain [String] the owning domain to filter records to
        # @yieldparam process_manager [String] the process manager's name
        # @yieldparam correlation [String] the instance's correlation value
        # @yieldparam state [String] the saga's state name
        # @yieldparam memory [Hash{Symbol => Object}] the saga's memory, Symbol keys at every
        #   depth
        # @yieldparam completed_compensations [Array] the completed-compensation ledger
        # @return [Enumerator, Hash{String => Hash}] an enumerator when no block is given
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

        # Space-joined; the key is opaque and never parsed back, so spaces in a
        # correlation value are harmless.
        def key_for(domain, process_manager, correlation) = [domain, process_manager, correlation].join(" ")
      end
    end
  end
end
