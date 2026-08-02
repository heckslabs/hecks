require "zlib"

module Hecksagain
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

        def write(records)
          sorted = records.sort_by { |id, _| id }.to_h
          json   = JSON.generate(sorted)

          File.binwrite(
            @path,
            MAGIC + [sorted.size].pack("N") + Zlib::Deflate.deflate(json, Zlib::BEST_COMPRESSION)
          )
        end
      end
    end
  end
end
