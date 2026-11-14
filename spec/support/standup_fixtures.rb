# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "priority_report_fixtures"
require "hecks/tickets/bluebook/adapters/standup"

# A seeded Work ledger, a temporary event tap and fixed machine readings, with the standup read
# from them, for the Work.standup specs.
module StandupFixtures
  include PriorityReportFixtures

  # Noon on a fixed day, in epoch seconds: the time every standup of these specs is read at.
  NOON = Time.utc(2026, 11, 14, 12).to_i

  GAUGES = { cpu_idle: 60.1, swap_used: 12.5, compressor_gb: 4.25, free_gb: 2.3, load: 3.2 }.freeze

  def tap = @tap ||= File.join(Dir.mktmpdir("standup"), "events.jsonl")

  def tap_line(event, id, hours_ago, seq)
    at = Time.at(NOON - (hours_ago * 3600)).utc.iso8601
    JSON.generate(kind: "event", at: at, aggregate: "Tickets::Work", id: id, event: event, seq: seq)
  end

  def finished(*pairs)
    lines = pairs.each_with_index.map { |(id, hours_ago), index| tap_line("WorkFinished", id, hours_ago, index + 1) }
    File.write(tap, "#{lines.join("\n")}\n")
  end

  def standup_registry(entries)
    window = double(hecks_name: "StandupWindow", members: [{ hours: 24, upcoming: 3 }])
    kinds = double(hecks_name: "YieldKind", members: [{ kind: "load", first: true }])
    bluebook = double(aggregates: [double(hecks_name: "Work", value_objects: [kinds, window])])
    double(bluebook: bluebook, repository: double(all: entries), world: double(for_verb: {}))
  end

  def standup(entries = seeded, gauges: GAUGES, **held)
    stand_ins = settings.merge(tap: tap, now: -> { NOON }, readings: -> { gauges })
    Hecks::Adapters::Standup.new(registry: standup_registry(entries), settings: stand_ins).standup(**held)[:text]
  end

  def section(text, heading) = text.split("\n\n").find { |part| part.start_with?(heading) }.to_s.lines.drop(1).map(&:strip)
end
