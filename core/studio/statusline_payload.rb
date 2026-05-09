# StatuslinePayload
#
# Builds the FROZEN /statusline JSON shape the terminal bar polls.
# The shape lives here as a single source of truth so a schema
# change is visible in one PR and the bar's parser can be updated
# in the same change.
#
# Frozen shape :
#   {
#     "state":      <string>          # consciousness state, e.g. "attentive"
#     "last_wake":  <iso-8601 | null>  # consciousness.last_wake_at
#     "last_dream": <string  | null>   # lucid_dream.latest_narrative
#                                      # OR consciousness.sleep_summary if
#                                      # in REM but no lucid narrative yet
#                                      # (only the final cycle is lucid ;
#                                      # cycles 1-7 produce DreamPulses
#                                      # that stamp sleep_summary, which
#                                      # the studio surfaces here too so
#                                      # the bar reads the actual current
#                                      # dream image rather than the stale
#                                      # last lucid one).
#     "features":   [{ "name", "status" }, ...]
#     "updated_at": <iso-8601>         # the moment we built this payload
#   }
#
# The bar is allowed to ignore unknown features (forward-compat) ;
# it MUST NOT see missing top-level keys (back-compat). Adding a
# top-level key requires a coordinated release with the bar.
#
# Usage :
#   StatuslinePayload.build(runtime: rt, heki_root: "/.../information")
#

require "time"
require_relative "feature_view"
require_relative "heki_view"

module StatuslinePayload
  CONSCIOUSNESS_HEKI = "consciousness/consciousness.heki".freeze
  LUCID_HEKI         = "lucid_dream/lucid_dream.heki".freeze

  module_function

  # Compose the payload. Keeps key order stable for human-readable
  # `curl | jq` output.
  #
  # @param runtime  [Hecks::Runtime]
  # @param heki_root [String] absolute path to miette-state/information
  # @return [Hash]
  def build(runtime:, heki_root:)
    consciousness = HekiView.first_record(File.join(heki_root, CONSCIOUSNESS_HEKI)) || {}
    lucid         = HekiView.first_record(File.join(heki_root, LUCID_HEKI)) || {}

    {
      state:      consciousness["state"] || consciousness[:state],
      last_wake:  consciousness["last_wake_at"] || consciousness[:last_wake_at],
      last_dream: pick_dream(consciousness, lucid),
      features:   feature_rows(runtime),
      updated_at: Time.now.utc.iso8601
    }
  end

  # Pick the freshest dream narrative. lucid_dream.latest_narrative is
  # only stamped during the final cycle's lucid REM. Regular REM (cycles
  # 1-7) emits DreamPulse which stamps consciousness.sleep_summary —
  # without this fallback the studio bar shows null for 7/8 of the
  # night even when dreams are streaming live. Prefers lucid when active
  # so the lucid badge in the bar keeps its provenance ; falls back to
  # sleep_summary during regular REM.
  def pick_dream(consciousness, lucid)
    state = consciousness["state"] || consciousness[:state]
    return nil unless state == "sleeping"
    lucid_active = lucid["active"] || lucid[:active]
    if lucid_active == "yes"
      lucid["latest_narrative"] || lucid[:latest_narrative]
    else
      consciousness["sleep_summary"] || consciousness[:sleep_summary]
    end
  end
  module_function :pick_dream

  # Reduce the FeatureView rows down to the {name,status} pair the
  # statusline needs. /health carries the wider shape ; the bar
  # only reads name + status.
  def feature_rows(runtime)
    FeatureView.rows(runtime).map { |r| { name: r[:name], status: r[:status] } }
  end
end
