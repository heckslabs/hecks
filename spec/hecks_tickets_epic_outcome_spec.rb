require "spec_helper"
require_relative "support/epic_outcome_looks"

# ADR 0206: an epic whose members are all closed completes only when the number its measure reads
# from the event tap is within the measure's bounds. A reading outside them keeps the epic open, or
# returns it to open, and plans the evidence as a new member; an epic that states no measure stays
# open and plans nothing.
RSpec.describe "the Tickets Epic's measured outcome" do
  include_context "with an epic outcome tap"

  it "completes when the members are closed and the reading is within its bounds", :aggregate_failures do
    epic
    close_members("m1", "m2")

    expect(status).to eq("complete")
    expect(evidence).to include("load-stays-under-its-mark read 0", "at most 0")
  end

  it "stays open when the reading is outside its bounds", :aggregate_failures do
    missed_epic(5, 20)

    expect(status).to eq("open")
    expect(event_count("EpicCompleted")).to eq(0)
  end

  it "plans the evidence of a miss as a new open member", :aggregate_failures do
    missed_epic(5, 20)

    expect(plain(evidence_item.status)).to eq("planned")
    expect(plain(evidence_item.epic)).to eq("e1")
    expect(plain(evidence_item.detail)).to include("read 2", "LoadRoseAbove", "at most 0", "Epic.review!")
  end

  it "leaves a reading older than the measure's window out" do
    write_tap(*load_rose(61, 90))
    epic
    close_members("m1")

    expect(status).to eq("complete")
  end

  it "plans a second evidence item when the outcome is missed again", :aggregate_failures do
    missed_epic(5)
    finish("e1-outcome-1")

    expect(work_keys).to include("e1-outcome-1", "e1-outcome-2")
    expect(status).to eq("open")
  end

  it "completes once the evidence item is finished and the outcome is met" do
    missed_epic(5)
    write_tap
    finish("e1-outcome-1")

    expect(status).to eq("complete")
  end

  it "reopens a complete epic whose outcome no longer holds, with the evidence", :aggregate_failures do
    missed_epic
    write_tap(*load_rose(5))
    cli("epic.review!", "to=e1")

    expect(status).to eq("open")
    expect(plain(evidence_item.epic)).to eq("e1")
  end

  it "keeps an epic that states no measure open, saying why, and plans nothing", :aggregate_failures do
    epic(nil)
    close_members("m1")

    expect(status).to eq("open")
    expect(evidence).to include("e1 states no measure", "Epic.measure_by!")
    expect(work_keys).to eq(%w[m1])
  end

  it "keeps an epic whose measure names no row open and plans nothing", :aggregate_failures do
    epic("no-such-measure")
    close_members("m1")

    expect(evidence).to include("no-such-measure names no OutcomeMeasure row")
    expect(work_keys).to eq(%w[m1])
  end

  def complete(reading)
    cli("epic.complete!", "to=e1", "members.value=1", "open_members.value=0", "reading.value=#{reading}",
        "at_least.value=0", "at_most.value=0", "evidence.value=by hand")
  end

  it "refuses to complete on a reading over its most", :aggregate_failures do
    epic

    expect(complete(1)).to include("an outcome read over its most does not complete")
    expect(status).to eq("open")
  end

  it "refuses to miss on a reading within its bounds" do
    epic
    miss = cli("epic.miss!", "to=e1", "reading.value=0", "at_least.value=0", "at_most.value=0",
               "evidence.value=by hand", "finding.value=e1-outcome-1")

    expect(miss).to include("an outcome read within its bounds is not missed")
  end

  it "refuses an empty measure" do
    epic(nil)

    expect(cli("epic.measure_by!", "to=e1", "measure.value= ")).to include("an epic names its measure")
  end
end
