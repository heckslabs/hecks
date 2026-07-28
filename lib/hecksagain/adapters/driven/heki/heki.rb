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

      def save(instance)
        current = store
        current[instance.id.to_s] = instance.state
        write(current)
        @store = current
        instance
      end

      def delete(id)
        current = store
        removed = current.delete(id.to_s)
        return false unless removed

        write(current)
        @store = current
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
    end
  end
end
