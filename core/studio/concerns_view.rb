# ConcernsView
#
# Read-only adapter that surfaces Doctor's Concern records to the
# Hecks Studio dashboard. Probes both plausible heki paths (the
# other agent owns the choice — Concern as its own aggregate vs.
# nested under Doctor) and returns a normalised list. Sorts by
# noted_at descending so the freshest concern is first. Returns []
# on missing file, parse error, or any unexpected shape so the
# dashboard renders cleanly even when Doctor isn't wired yet.
#
# Returned record shape (all fields optional ; renderer must
# tolerate nils) :
#   {
#     noted_at:      String  | nil    # iso-8601 timestamp
#     failure_kind:  String  | nil    # AggregateNotFound | LifecycleViolation | ...
#     aggregate:     String  | nil    # PascalCase aggregate name
#     command:       String  | nil    # PascalCase command name
#     script:        String  | nil    # offending script path
#     line:          Integer | nil    # offending line number
#     narrative:     String  | nil    # free-form explanation
#     severity:      :red | :orange | :yellow  # derived from failure_kind
#   }
#
# Usage :
#   recent = ConcernsView.recent       # array, capped at 10
#   total  = ConcernsView.window_count(60)  # last-60s count
#   kinds  = ConcernsView.window_kinds(60)  # { "AggregateNotFound" => 4, ... }
#

require "time"
require_relative "heki_view"

module ConcernsView
  CONCERN_HEKI = "doctor/concern/concern.heki".freeze
  DOCTOR_HEKI  = "doctor/doctor.heki".freeze

  # GivenFailed is filtered upstream — daemons routinely fail given
  # clauses for non-applicable transitions, that's not a body concern.
  FILTERED_KINDS = %w[GivenFailed].freeze

  RED_KINDS    = %w[AggregateNotFound].freeze
  ORANGE_KINDS = %w[LifecycleViolation].freeze

  DISPLAY_LIMIT = 10

  module_function

  # Full normalised list of Concern records, freshest first, with
  # filtered kinds removed. Used internally by `recent` (which caps
  # at DISPLAY_LIMIT) and the rolling-window helpers (which need the
  # full list to count by timestamp).
  def all(heki_root: HekiView::DEFAULT_ROOT)
    raw = load_raw(heki_root)
    raw
      .map  { |rec| normalise(rec) }
      .reject { |rec| FILTERED_KINDS.include?(rec[:failure_kind]) }
      .sort_by { |rec| rec[:noted_at].to_s }
      .reverse
  rescue StandardError
    []
  end

  # The 10 freshest concerns for the panel rows.
  def recent(heki_root: HekiView::DEFAULT_ROOT)
    all(heki_root: heki_root).first(DISPLAY_LIMIT)
  end

  # Count concerns whose noted_at is within the last `seconds` seconds.
  # Records with unparseable timestamps are excluded.
  def window_count(seconds, heki_root: HekiView::DEFAULT_ROOT, now: Time.now)
    in_window(seconds, heki_root: heki_root, now: now).length
  end

  # Hash of failure_kind => count for the rolling window. Useful for
  # the panel header summary.
  def window_kinds(seconds, heki_root: HekiView::DEFAULT_ROOT, now: Time.now)
    in_window(seconds, heki_root: heki_root, now: now).each_with_object(Hash.new(0)) do |rec, acc|
      acc[rec[:failure_kind] || "Unknown"] += 1
    end
  end

  # True iff any single kind has crossed the EscalateOnSustainedConcerns
  # policy threshold (>10 of one kind in the last 60 seconds).
  def escalating?(heki_root: HekiView::DEFAULT_ROOT, now: Time.now)
    window_kinds(60, heki_root: heki_root, now: now).values.any? { |n| n > 10 }
  end

  # ---- internal ----------------------------------------------

  def load_raw(heki_root)
    [CONCERN_HEKI, DOCTOR_HEKI].each do |rel|
      path = File.join(heki_root, rel)
      next unless File.exist?(path)
      data = HekiView.read(path)
      records = extract_concerns(data)
      return records unless records.empty?
    end
    []
  end
  module_function :load_raw

  # Pull a flat list of Concern records out of a heki hash. Three
  # plausible shapes :
  #   1. Concern aggregate     : { "<id>" => { ...concern fields... } }
  #   2. Doctor.current_concerns : { "<id>" => { "current_concerns" => [...] } }
  #   3. Doctor.noted_concerns   : { "<id>" => { "noted_concerns"  => [...] } }
  # current_concerns are open ones (lifecycle-cleared by AllClear) ;
  # noted_concerns is the historical log of every ConcernNoted. The
  # studio surfaces noted_concerns when present so cleared concerns
  # still show up in the rolling 60s window. We try every list-y key
  # we know about and concatenate.
  CONCERN_LIST_KEYS = %w[noted_concerns current_concerns concerns].freeze

  def extract_concerns(data)
    return [] unless data.is_a?(Hash)

    nested = data.values.flat_map do |v|
      next [] unless v.is_a?(Hash)
      CONCERN_LIST_KEYS.flat_map do |key|
        list = v[key] || v[key.to_sym]
        list.is_a?(Array) ? list : []
      end
    end
    return nested unless nested.empty?

    data.values.select { |v| v.is_a?(Hash) && concern_like?(v) }
  end
  module_function :extract_concerns

  def concern_like?(hash)
    keys = hash.keys.map(&:to_s)
    keys.include?("noted_at") || keys.include?("failure_kind") ||
      keys.include?("daemon_name")
  end
  module_function :concern_like?

  def normalise(rec)
    {
      noted_at:     pick(rec, :noted_at),
      failure_kind: pick(rec, :failure_kind),
      aggregate:    pick(rec, :aggregate)  || pick(rec, :aggregate_name),
      command:      pick(rec, :command)    || pick(rec, :command_name),
      script:       pick(rec, :script),
      line:         pick(rec, :line),
      narrative:    pick(rec, :narrative)  || pick(rec, :daemon_name),
      severity:     severity_for(pick(rec, :failure_kind))
    }
  end
  module_function :normalise

  # Read by either string or symbol key — heki payloads are JSON
  # (string keys) but in-memory aggregates may hand symbols.
  def pick(rec, key)
    rec[key.to_s] || rec[key]
  end
  module_function :pick

  def severity_for(kind)
    return :red    if RED_KINDS.include?(kind)
    return :orange if ORANGE_KINDS.include?(kind)
    :yellow
  end
  module_function :severity_for

  def in_window(seconds, heki_root:, now:)
    cutoff = now - seconds
    all(heki_root: heki_root).select do |rec|
      ts = parse_time(rec[:noted_at])
      ts && ts >= cutoff
    end
  end
  module_function :in_window

  def parse_time(value)
    return nil if value.nil? || value.to_s.empty?
    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end
  module_function :parse_time
end
