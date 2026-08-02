require "json"
require "fileutils"
require_relative "heki/snapshot"
require_relative "heki/journal"

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

        FileUtils.mkdir_p(File.dirname(@path))
      end

      def find(id)
        record = store[id.to_s]
        return nil unless record

        instance(id.to_s, record)
      end

      def all
        store.sort_by { |id, _| id }.map { |id, record| instance(id, record) }
      end

      def count = store.size

      def query(specification, args = {}, context: {})
        Ports::Query::InMemory.execute(all, specification, args)
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

      private

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
