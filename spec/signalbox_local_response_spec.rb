# frozen_string_literal: true

require "spec_helper"
require "hecks/signalbox/adapters/local_response"
require "hecks/hecks/adapters/codebase/session_kind"

# Each session kind answers the pressure band by Signalbox's own Response table (ADR 0222 law 3),
# asked from a heavy job's process; the kind is read from the job's environment and an unknown
# caller runs as a person.
RSpec.describe Hecks::Adapters::LocalResponse do
  # The table is booted alone in Memory, as a heavy job boots it.
  let(:table) { described_class.new }

  def kind(caller = nil, job = "spec_batch", **marks)
    base = { "HECKS_CALLER" => caller }.merge(marks.transform_keys(&:to_s)).compact
    Hecks::Adapters::Codebase::SessionKind.of(base, job)
  end

  # The probe of 2026-11-20 09:13: pressure tight with 7 items in flight. Tight holds starts, never
  # the heavy jobs of work in flight.
  it "does not hold the item at its landing spec run when pressure is tight" do
    expect(table.answer(**kind("landing:item-7", HECKS_HEAVY_KIND: "landing"), band: "tight")).to eq("running")
  end

  it "does not hold a coder's spec run when pressure is tight" do
    expect(table.answer(**kind("coder:item-7"), band: "tight")).to eq("running")
  end

  it "has a lower-tier coder defer its heavy steps when pressure is short" do
    expect(table.answer(**kind("coder:item-7"), band: "short")).to eq("deferring")
  end

  it "has a dispatched helper finish and leave when pressure is short" do
    expect(table.answer(**kind("reviewer:p-walk"), band: "short")).to eq("leaving")
  end

  it "has a landing's gate wait its turn when pressure is short" do
    expect(table.answer(**kind("landing:item-7", HECKS_HEAVY_KIND: "landing"), band: "short")).to eq("waiting")
  end

  it "keeps an urgent landing's gate running when pressure is short" do
    marks = { HECKS_HEAVY_KIND: "landing", HECKS_HEAVY_PRIORITY: "urgent" }
    expect(table.answer(**kind(nil, **marks), band: "short")).to eq("running")
  end

  it "runs a ticker's job as a person's, never refused" do
    expect(table.answer(**kind("ticker"), band: "short")).to eq("running")
  end

  it "runs every kind in normal pressure" do
    expect(table.answer(**kind("reviewer:p-walk"), band: "normal")).to eq("running")
  end
end
