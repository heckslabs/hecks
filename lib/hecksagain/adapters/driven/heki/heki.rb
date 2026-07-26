# Heki — the append-log persistence adapter, in Ruby.
#
# THE FILE FORMAT IS THE CONTRACT, and it is Hecks's :
#
#   "HEKI"                4 bytes, magic
#   record count          u32, big-endian
#   zlib-compressed JSON  a map of { id => record }
#
# Written so the two runtimes can read each other's stores. That is a stronger
# claim than "both work" : a format one side can write and the other cannot read
# is two formats wearing one extension, and it would not surface until someone
# switched runtimes on a directory that already had data in it.
#
# BYTE-IDENTITY IS NOT AVAILABLE HERE, and it is worth saying why rather than
# leaving it to be discovered. Rust's Store is a HashMap, so serde emits its keys
# in whatever order the map iterates — two Rust runs over the same records need
# not produce the same file. This side sorts keys before writing, which makes
# RUBY's output reproducible, and no amount of care on this side can make the
# bytes match. Compare decoded stores, never files.
#
# IN-PROCESS, like every persistence adapter — see heki.adapter for why that is
# the one impure edge allowed to be.
#
#   Heki.new(aggregate: account_ir, settings: { dir: "data" })
require "json"
require "zlib"
require "fileutils"

module Hecksagain
  module Adapters
    class Heki
      MAGIC = "HEKI"
      # The 4-byte magic plus the 4-byte count. Anything shorter is not a heki
      # file, whatever it is called.
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

      # Sorted by id, so a listing does not depend on how a hash happened to
      # iterate. Two runs of the same domain answer in the same order.
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

      # Events are held in memory, deliberately. They are a SEPARATE concern
      # from persistence — the runtime owns the log — and a heki store is a map
      # keyed by aggregate id, which has nowhere to put an ordered stream.
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

      # Read once, then keep it. A store is the whole file, so re-reading per
      # find would decompress the entire aggregate to answer one lookup.
      def store
        @store ||= read
      end

      def read
        return {} unless File.exist?(@path)

        data = File.binread(@path)
        raise Malformed, "#{@path}: too short" if data.bytesize < HEADER_BYTES
        raise Malformed, "#{@path}: bad magic" unless data[0, 4] == MAGIC

        # The count in the header is not trusted as truth — the JSON is. It is a
        # readability aid for anyone looking at the file with `xxd`, and a
        # cross-check we could make but do not, because disagreeing with the
        # payload would mean the file is damaged in a way a count cannot fix.
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

      # One store per aggregate, named for it — the same snake_case rule that
      # turns an aggregate into a table name, so the two adapters agree about
      # what a thing is called.
      def resolve_path(settings, root)
        declared = settings[:dir] || settings["dir"] || "data"
        dir      = declared.start_with?("/") ? declared : File.join(root || Dir.pwd, declared)

        File.join(dir, "#{@aggregate.storage_name}.heki")
      end
    end
  end
end
