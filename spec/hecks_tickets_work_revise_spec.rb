require "spec_helper"

# Drives the Tickets Work commands through the CLI of a Memory-booted Hecks domain.
module WorkReviseHelpers
  FIELDS = %w[status claimed_by claimed_at priority step area].freeze

  def hecks = @hecks ||= boot_hecks_in_memory

  def cli_text(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv])
    out
  end

  def run_cli(*argv) = JSON.parse(cli_text(*argv))

  def row(key = "w/a") = run_cli("work.undone").find { |found| found["work"] == key }

  def snapshot = row.values_at(*FIELDS)

  def started_item(key = "w/a")
    run_cli("work.plan!", "work.value=#{key}", "title.value=Old", "detail.value=Old", "step.value=2",
            "area=lib/hecks/tickets")
    cli_text("work.prioritize!", "to=#{key}", "priority.value=now")
    run_cli("work.start!", "to=#{key}", "claimed_by.value=session-a", "claimed_at.value=2026-11-03T09:00:00Z",
            "area=lib/hecks/tickets")
  end

  def revise(key = "w/a") = cli_text("work.revise!", "to=#{key}", "title.value=New", "detail.value=New")
end

# Revising an open Work item moves its title and detail and nothing else: the status, claim,
# priority, step and area stay as they were. Area moves through Rescope and ClearArea, and a done
# or dropped item takes none of them. Each example boots its own Hecks domain.
RSpec.describe "Work revise" do
  include WorkReviseHelpers

  it "keeps status, claim, priority, step and area of a started item", :aggregate_failures do
    started_item
    before = snapshot
    revise

    expect(snapshot).to eq(before)
    expect(row["title"]).to eq("New")
  end

  it "replaces the whole area on Rescope and keeps the claim", :aggregate_failures do
    started_item
    cli_text("work.rescope!", "to=w/a", "area=lib/hecks/a")

    expect(row["area"].to_s).to include("lib/hecks/a").and(satisfy { |text| !text.include?("tickets") })
    expect(row["claimed_by"]).to eq("session-a")
  end

  it "empties the area on ClearArea and keeps the claim", :aggregate_failures do
    started_item
    cli_text("work.clear_area!", "to=w/a")

    expect(row["area"]).to be_nil.or be_empty
    expect(row["status"]).to eq("started")
  end

  it "refuses to revise a done item, naming its state" do
    started_item
    cli_text("work.finish!", "to=w/a")

    expect(revise).to include("done")
  end
end
