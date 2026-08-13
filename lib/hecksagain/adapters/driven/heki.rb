require "json"
require "fileutils"
require_relative "heki/snapshot"
require_relative "heki/journal"
require_relative "heki/saga_store"
require_relative "../../ports/persistence/append_only"
require_relative "../../ports/query/in_memory"
require_relative "in_memory_ordering"
require_relative "../../runtime/instance"

module Hecksagain
  module Adapters
    # The file-backed store: a compressed snapshot (heki/snapshot.rb)
    # plus an append-only journal beside it (heki/journal.rb). What stays
    # here is the repository surface — find/all/save/delete, and the
    # entry append/project pair the persistence port drives.
    class Heki
      include Snapshot
      include Journal

      MAGIC = "HEKI"
      HEADER_BYTES = 8

      class Malformed < StandardError; end

      attr_reader :aggregate, :path

      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate
        @path      = resolve_path(settings, root)
        @journal_path = "#{@path}.journal"
        @events    = []
        # THE OPTIONAL saga-persistence capability's own scoping (§2/§4)
        # — falls back to the aggregate's own name for a directly-
        # instantiated adapter (specs), same fallback shape Postgres's
        # own @domain already uses.
        @domain    = (settings[:domain] || settings["domain"] || aggregate.name).to_s

        FileUtils.mkdir_p(File.dirname(@path))
      end

      def find(id)
        record = store[id.to_s]
        return nil unless record

        instance(id.to_s, record)
      end

      def all(order_by: nil, direction: :asc)
        records = store.sort_by { |id, _| id }.map { |id, record| instance(id, record) }
        InMemoryOrdering.ordered(records, aggregate: @aggregate, order_by: order_by, direction: direction)
      end

      def count = store.size

      # `registry: context[:registry]` — Memory's own `query` already
      # threads this through; Heki's own never did, which made
      # `none_in_state?` (Ports::Query::InMemory) unconditionally
      # return `true` (its own graceful "no registry, no way to look
      # the target up" default) for EVERY `none_in_state` where-clause
      # against a Heki-backed aggregate — silently excluding nothing,
      # always, no matter the actual target state.
      def query(specification, args = {}, context: {})
        Ports::Query::InMemory.execute(all, specification, args, registry: context[:registry])
      end

      def append(entry)
        @entry_mirrors = entry.mirrors
        append_entry(entry.operation, entry.id, entry.state)
        entry
      ensure
        @entry_mirrors = nil
      end

      def project(entry)
        current = store
        entry.save? ? current[entry.id] = entry.state.dup : current.delete(entry.id)
        write(current)
        @store = current
        entry
      end

      def save(instance)
        entry = Ports::Persistence::Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup)
        append(entry)
        project(entry)
        instance
      end

      def delete(id)
        return false unless find(id)

        entry = Ports::Persistence::Entry.new(operation: "delete", id: id.to_s, state: nil)
        append(entry)
        project(entry)
        true
      end

      def record_event(event) = @events << event

      def events = @events

      # ── the OPTIONAL saga-persistence capability (§2) — Heki's own
      # shape (a sibling snapshot+journal file pair, `SagaStore`,
      # heki/saga_store.rb) rather than a table in a store this adapter
      # doesn't have.
      def save_saga(process_manager:, correlation:, state:, memory:)
        saga_store.save_saga(@domain, process_manager.to_s, correlation.to_s, state.to_s, memory)
      end

      def delete_saga(process_manager:, correlation:)
        saga_store.delete_saga(@domain, process_manager.to_s, correlation.to_s)
      end

      def each_saga(&block) = saga_store.each_saga(@domain, &block)

      private

      def saga_store
        @saga_store ||= SagaStore.new(File.dirname(@path))
      end

      def instance(id, record)
        Runtime::Instance.new(
          aggregate: @aggregate,
          id:        id,
          state:     record.transform_keys(&:to_sym)
        )
      end

      def store
        @store ||= read
      end

      def read
        snapshot = read_snapshot
        replay_journal(snapshot)
      end

      def resolve_path(settings, root)
        declared = settings[:dir] || settings["dir"] || "data"
        dir      = declared.start_with?("/") ? declared : File.join(root || Dir.pwd, declared)

        File.join(dir, "#{@aggregate.storage_name}.heki")
      end
    end
  end
end
