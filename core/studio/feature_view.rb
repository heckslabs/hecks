# FeatureView
#
# Adapter from a Hecks::Runtime to the array of feature rows the
# /health and /statusline endpoints return. Pulls TickedFeature
# records, normalises the field names the JSON shape contracts
# guarantee.
#
# Usage :
#   rows = FeatureView.rows(runtime)
#   # => [{ name:, status:, last_tick_at:, expected_interval_ms: }, ...]
#

module FeatureView
  AGGREGATE = "TickedFeature".freeze

  module_function

  # Return TickedFeature rows as an array of plain hashes with the
  # keys /health and /statusline contract on. Empty array when the
  # runtime has no records (fresh boot, before any tick).
  #
  # @param runtime [Hecks::Runtime]
  # @return [Array<Hash>]
  def rows(runtime)
    repo = runtime[AGGREGATE]
    return [] unless repo && repo.respond_to?(:all)

    repo.all.map { |rec| row_for(rec) }
  rescue StandardError
    []
  end

  # Single-row mapping. Keeps the field order stable across
  # /health and /statusline so the frozen schema stays frozen.
  def row_for(rec)
    {
      name: read(rec, :name),
      status: read(rec, :status) || "pending",
      last_tick_at: read(rec, :last_tick_at),
      expected_interval_ms: read(rec, :expected_interval_ms)
    }
  end

  # Read an attribute off a runtime record without caring whether
  # it's an OpenStruct, a struct-y aggregate, or a hash.
  def read(rec, attr)
    if rec.respond_to?(attr)
      rec.send(attr)
    elsif rec.is_a?(Hash)
      rec[attr] || rec[attr.to_s]
    end
  end
end
