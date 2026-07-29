require "json"
require "zlib"
require "fileutils"

module Hecksagain
  module Adapters
    class Heki
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

      def entries
        return [] unless File.exist?(@journal_path)

        File.readlines(@journal_path, chomp: true).reject(&:empty?).map do |line|
          value = JSON.parse(line)
          state = value["state"]&.transform_keys(&:to_sym)
          Ports::Persistence::Entry.new(operation: value.fetch("operation"), id: value.fetch("id"), state: state, mirrors: value["mirrors"])
        end
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

      def read_snapshot
        return {} unless File.exist?(@path)

        data = File.binread(@path)
        raise Malformed, "#{@path}: too short" if data.bytesize < HEADER_BYTES
        raise Malformed, "#{@path}: bad magic" unless data[0, 4] == MAGIC

        JSON.parse(Zlib::Inflate.inflate(data[HEADER_BYTES..]))
      rescue Zlib::DataError => e
        raise Malformed, "#{@path}: zlib error: #{e.message}"
      rescue JSON::ParserError => e
        raise Malformed, "#{@path}: json error: #{e.message}"
      end

      def replay_journal(records)
        return records unless File.exist?(@journal_path)

        File.foreach(@journal_path) do |line|
          entry = JSON.parse(line)
          id    = entry.fetch("id")

          case entry.fetch("operation")
          when "save"   then records[id] = entry.fetch("state")
          when "delete" then records.delete(id)
          else raise Malformed, "#{@journal_path}: unknown journal operation #{entry.fetch("operation").inspect}"
          end
        end
        records
      rescue JSON::ParserError => e
        raise Malformed, "#{@journal_path}: json error: #{e.message}"
      end

      def write(records)
        sorted = records.sort_by { |id, _| id }.to_h
        json   = JSON.generate(sorted)

        File.binwrite(
          @path,
          MAGIC + [sorted.size].pack("N") + Zlib::Deflate.deflate(json, Zlib::BEST_COMPRESSION)
        )
      end

      def resolve_path(settings, root)
        declared = settings[:dir] || settings["dir"] || "data"
        dir      = declared.start_with?("/") ? declared : File.join(root || Dir.pwd, declared)

        File.join(dir, "#{@aggregate.storage_name}.heki")
      end

      def append_entry(operation, id, state)
        File.open(@journal_path, "ab") do |journal|
          journal.write(JSON.generate(operation: operation, id: id.to_s, state: state, mirrors: @entry_mirrors))
          journal.write("\n")
          journal.flush
          journal.fsync
        end
      end
    end
  end
end
