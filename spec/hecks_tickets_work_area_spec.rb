require "spec_helper"

# A started Work item claims the area it declares, and a start whose area overlaps another started
# row's is sent back to the plan with the row and the path named. Each example boots its own
# Memory domain, so no claim leaks into another.
RSpec.describe "Work area claims" do
  let(:hecks) { boot_hecks_in_memory }

  def cli(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv])
    out
  end

  def plan(key) = cli("work.plan!", "work.value=#{key}", "title.value=Step #{key}", "decision=0174")

  def start(key, *area)
    plan(key)
    cli("work.start!", "to=#{key}", "claimed_by.value=s", "claimed_at.value=2026-10-31T09:00:00Z",
        *area.map { |path| "area.value=#{path}" })
    row(key)
  end

  def row(key) = JSON.parse(cli("work.undone")).find { |work| work["work"] == key }

  it "starts a row that declares an area", :aggregate_failures do
    work = start("area/a", "lib/hecks/tickets")

    expect(work["status"]).to eq("started")
    expect(work["area"]).to eq(["lib/hecks/tickets"])
  end

  it "sends back a start that overlaps a started work item, naming it and the path", :aggregate_failures do
    start("area/b", "lib/hecks/tickets")
    work = start("area/c", "lib/hecks/tickets/bluebook")

    expect(work["status"]).to eq("planned")
    expect(work["reason"]).to include("area/b", "lib/hecks/tickets")
  end

  it "drops the claim of a row sent back to the plan", :aggregate_failures do
    start("area/k", "lib/hecks/tickets")
    work = start("area/l", "lib/hecks/tickets")

    expect(work.values_at("claimed_by", "claimed_at", "budget_minutes")).to eq(["", "", 0])
    expect(work["area"]).to be_empty
  end

  it "drops the claim of a released row", :aggregate_failures do
    start("area/m", "lib/x")
    cli("work.release!", "to=area/m")

    expect(row("area/m").values_at("claimed_by", "claimed_at", "budget_minutes")).to eq(["", "", 0])
    expect(row("area/m")["area"]).to be_empty
  end

  it "refuses to start a row that names no claimant" do
    plan("area/n")
    cli("work.start!", "to=area/n", "claimed_by.value=", "claimed_at.value=2026-10-31T09:00:00Z")

    expect(row("area/n")["status"]).to eq("planned")
  end

  it "starts a row whose area does not overlap" do
    start("area/d", "lib/hecks/tickets")

    expect(start("area/e", "lib/hecks/deliver")["status"]).to eq("started")
  end

  it "starts a row with no area, which claims nothing" do
    start("area/f", "lib")

    expect(start("area/g")["status"]).to eq("started")
  end

  it "frees the area when the holder is released" do
    start("area/h", "lib/x")
    cli("work.release!", "to=area/h")

    expect(start("area/i", "lib/x")["status"]).to eq("started")
  end

  it "frees the area when the holder finishes" do
    start("area/j", "lib/y")
    cli("work.finish!", "to=area/j")

    expect(start("area/k", "lib/y")["status"]).to eq("started")
  end
end
