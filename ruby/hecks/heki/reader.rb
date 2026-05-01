# Hecks::Heki::Reader
#
# Purpose: Ruby-side reader for .heki files. Parses the binary envelope
# used by the Rust hecks-life runtime (4-byte "HEKI" magic, big-endian
# u32 record count, zlib-deflated JSON payload) and returns the
# decoded hash of records. Prerequisite for the i30 differential
# fuzzer, which round-trips .heki files between Ruby and Rust to
# detect format drift.
#
# Usage:
#   data = Hecks::Heki::Reader.read("hecks_conception/information/identity.heki")
#   data.each { |id, record| puts id }
#
require "zlib"
require "json"

module Hecks
  module Heki
    MAGIC = "HEKI".b

    class InvalidFormatError < StandardError; end

    module Reader
      module_function

      def read(path)
        bytes = File.binread(path)
        raise InvalidFormatError, "bad magic" unless bytes.start_with?(MAGIC)
        raise InvalidFormatError, "truncated header" if bytes.bytesize < 8
        count = bytes[4, 4].unpack1("N")   # big-endian u32
        payload = bytes[8..] || "".b
        begin
          inflated = Zlib::Inflate.inflate(payload)
        rescue Zlib::DataError => e
          raise InvalidFormatError, "zlib: #{e.message}"
        end
        data = JSON.parse(inflated)
        raise InvalidFormatError, "not hash" unless data.is_a?(Hash)
        raise InvalidFormatError, "count mismatch #{count} vs #{data.size}" if count != data.size
        data
      rescue Errno::ENOENT
        raise InvalidFormatError, "file not found: #{path}"
      end
    end
  end
end
