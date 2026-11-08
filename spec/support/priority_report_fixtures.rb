# frozen_string_literal: true

require_relative "roll_forward_fixtures"
require "hecks/tickets/bluebook/adapters/priority_report"

# A seeded Work ledger and the priority report read from it, for the Work.priority_report specs.
module PriorityReportFixtures
  include RollForwardFixtures

  def record(key, status: "planned", priority: nil, step: nil, area: key)
    Entry.new(work: key, title: key, status: status, priority: priority, step: step, area: [Word.new(area)], detail: "")
  end

  def seeded
    [record("later-b", priority: "later", step: 1), record("now-a", priority: "now", step: 2),
     record("plain-c"), record("red-z", step: 9), record("next-d", priority: "next", step: 1),
     record("now-e", priority: "now", step: 1), record("run-1", status: "started")]
  end

  def settings(cap: 2) = { load: -> { 0.5 }, cpus: 4, cap: cap }

  def adapter(entries = seeded, cap: 2)
    Hecks::Adapters::PriorityReport.new(registry: registry_of(entries), settings: settings(cap: cap))
  end

  def report(entries = seeded, cap: 2, **held) = adapter(entries, cap: cap).priority_report(**held)[:text].lines.map(&:chomp)

  def keys(lines) = lines.drop(1).map { |line| line.strip.split(/\s{2,}/)[3] }
end
