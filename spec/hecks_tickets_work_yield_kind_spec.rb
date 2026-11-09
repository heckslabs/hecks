require "spec_helper"
require "json"

# Work.yield! records the kind of a yield, and a yield with none clears the last one.
RSpec.describe "the kind a Work yield records" do
  let(:hecks) { boot_hecks_in_memory }

  def cli(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv])
    out
  end

  def row = JSON.parse(cli("work.undone")).find { |work| work["work"] == "k" }

  def start
    cli("work.plan!", "work.value=k", "title.value=K")
    cli("work.start!", "to=k", "claimed_by.value=s", "claimed_at.value=2026-11-01T09:00:00Z")
  end

  def yield_with(*extra) = cli("work.yield!", "to=k", "reason.value=r", *extra)

  it "keeps the kind, the retry time and the count", :aggregate_failures do
    start
    yield_with("yield_kind.value=transient", "retry_at.value=2026-11-01T09:05:00Z", "yield_count.value=1")

    kept = row.values_at("status", "yield_kind", "retry_at", "yield_count")

    expect(kept).to eq(["planned", "transient", "2026-11-01T09:05:00Z", 1])
  end

  def plain(value) = value.respond_to?(:value) ? value.value : value

  def record
    aggregate = hecks.registry.bluebook("Tickets").aggregates.find { |declared| declared.hecks_name == "Work" }
    hecks.registry.repository("Tickets", aggregate).all.last
  end

  def finish_after_two_yields
    start
    yield_with("yield_kind.value=transient", "retry_at.value=2026-11-01T09:05:00Z", "yield_count.value=2")
    cli("work.start!", "to=k", "claimed_by.value=s", "claimed_at.value=2026-11-01T09:10:00Z")
    cli("work.finish!", "to=k")
  end

  it "forgets its yields when the work item is finished", :aggregate_failures do
    finish_after_two_yields

    expect(plain(record.yield_kind).to_s).to be_empty
    expect(plain(record.yield_count).to_i).to eq(0)
  end

  it "clears the kind when a later yield names none" do
    start
    yield_with("yield_kind.value=transient", "retry_at.value=2026-11-01T09:05:00Z", "yield_count.value=1")
    cli("work.start!", "to=k", "claimed_by.value=s", "claimed_at.value=2026-11-01T09:10:00Z")
    yield_with

    expect(row["yield_kind"].to_s).to be_empty
  end
end
