require "zlib"

module Hecks
  module Adapters
    class Heki
      # The binary snapshot codec: magic-header framing around
      # deflate-compressed, id-sorted JSON. Reading refuses loudly on a
      # short file, a bad magic, or a body neither zlib nor JSON will own.
      module Snapshot
        private

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

        # Temp file, fsync, then rename, so a reader never sees a partial snapshot.
        def write(records)
          sorted = records.sort_by { |id, _| id }.to_h
          json   = JSON.generate(sorted)
          body   = MAGIC + [sorted.size].pack("N") + Zlib::Deflate.deflate(json, Zlib::BEST_COMPRESSION)
          tmp    = "#{@path}.tmp.#{Process.pid}.#{object_id}"

          File.open(tmp, "wb") do |file|
            file.write(body)
            file.flush
            file.fsync
          end
          File.rename(tmp, @path)
        end

        # Serializes each save/delete's read-modify-write across processes; `flock` is
        # advisory, so every writer must use it. The lock file is separate from `@path`
        # so a held lock never blocks `write`'s rename.
        def with_lock
          File.open(lock_path, File::CREAT | File::RDWR, 0o644) do |lock|
            lock.flock(File::LOCK_EX)
            yield
          ensure
            lock.flock(File::LOCK_UN)
          end
        end

        def lock_path = "#{@path}.lock"
      end
    end
  end
end
