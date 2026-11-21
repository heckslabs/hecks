# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/rules"

# Each kind of thing that can stand too long has a mark declared as a board `Setting`, and a
# `Verdict` stage that compares the age with it. Past its mark the kind reads `too long`.
# A kind that waits on a person at once, such as a red main given up, has no mark.
RSpec.describe "the marks past which a stuck item has stood too long" do
  let(:rules) { Hecks::Adapters::PipelineBoard::Rules }
  let(:kinds) { rules.rows("StuckKind") }

  it "names a Setting for every kind's mark", :aggregate_failures do
    names = rules.rows("Setting").map { |row| row[:name] }
    expect(kinds.map { |kind| kind[:mark] }.reject(&:empty?)).to all(satisfy { |mark| names.include?(mark) })
    expect(kinds.map { |kind| kind[:kind] }).to include("red_main", "epic_held", "planned_idle")
  end

  %w[red_main train_blocked blocked_run owner_ask approval_awaited epic_held planned_idle].each do |name|
    it "reads #{name} as too long past its mark and in time at it", :aggregate_failures do
      kind = kinds.find { |row| row[:kind] == name }
      mark = rules.setting(kind[:mark])
      expect(rules.verdict(kind[:judged_by], { age_minutes: mark + 1 })).to eq("too long")
      expect(rules.verdict(kind[:judged_by], { age_minutes: mark })).to eq("in time")
    end
  end

  it "reads an age that could not be read as unknown" do
    expect(rules.verdict("Red main age", { age_minutes: nil })).to eq("unknown")
  end

  it "keeps the stopped run and the stalled session on the marks they already had", :aggregate_failures do
    expect(rules.verdict("Stopped run age", { hours: 5 })).to eq("overdue")
    expect(rules.verdict("Session idle", { idle_seconds: 901 })).to eq("attention")
  end
end
