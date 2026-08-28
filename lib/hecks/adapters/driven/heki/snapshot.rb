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

        # Temp-file-plus-rename, fsynced before the rename: a reader can
        # only ever see the last complete snapshot or the one before it,
        # never a truncated or partial one — `File.binwrite`'s old
        # truncate-then-write left a window, proportional to the whole
        # dataset, where the file on disk was neither.
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

        # Serializes the read-modify-write each save/delete does against
        # the snapshot (and the journal append that precedes it) across
        # processes — `flock` is per-process advisory, so every writer
        # has to go through this to matter, which `with_lock`'s only two
        # callers (`Heki#save`/`#delete`, `SagaStore#save_saga`/
        # `#delete_saga`) both do. The lock file is separate from
        # `@path` so a held lock never blocks `write`'s own rename.
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
