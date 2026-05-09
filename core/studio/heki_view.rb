# HekiView
#
# Minimal heki reader for the studio's read-only views into
# Miette's brain. Wraps Hecks::Heki::Reader if available, falls
# back to an inline reader otherwise. Returns {} on any error so
# the dashboard never crashes from a missing/corrupt heki.
#
# A heki file is "HEKI" magic + 4-byte big-endian record count +
# zlib-deflated JSON hash payload.
#
# Usage :
#   c = HekiView.read("/.../consciousness/consciousness.heki")
#   c["consciousness"]["state"] # => "attentive"
#

require "zlib"
require "json"

module HekiView
  DEFAULT_ROOT = "/Users/christopheryoung/Projects/miette-state/information"

  module_function

  # Read a heki file and return the decoded record hash, or {} on
  # any error. Tries Hecks::Heki::Reader first if loaded ; falls
  # back to an inline parser otherwise so the studio works without
  # the heki extension being required upstream.
  #
  # @param path [String] absolute path to the .heki file
  # @return [Hash]
  def read(path)
    return {} unless File.exist?(path)

    if defined?(Hecks::Heki::Reader)
      begin
        return Hecks::Heki::Reader.read(path)
      rescue StandardError
        # Fall through to inline reader.
      end
    end

    inline_read(path)
  rescue StandardError
    {}
  end

  # Read a single named record from a heki keyed by id.
  # @param path [String]
  # @param key  [String]
  # @return [Hash, nil]
  def record(path, key)
    data = read(path)
    return nil unless data.is_a?(Hash)
    data[key] || data[key.to_s]
  end

  # Read the first record from a heki — useful for singletons that
  # may have been stored under different ids over time.
  # @param path [String]
  # @return [Hash, nil]
  def first_record(path)
    data = read(path)
    return nil unless data.is_a?(Hash) && data.any?
    data.values.first
  end

  # Inline heki reader — same envelope as Hecks::Heki::Reader but
  # without the magic/count strict checks (we tolerate drift here ;
  # the studio is read-only).
  def inline_read(path)
    bytes = File.binread(path)
    return {} if bytes.bytesize < 9
    payload = bytes[8..] || "".b
    inflated = Zlib::Inflate.inflate(payload)
    parsed = JSON.parse(inflated)
    parsed.is_a?(Hash) ? parsed : {}
  end
end
