require "spec_helper"
require "json"
require_relative "support/new_work_started"

# A batch is one coder session for several planned work items: its lead is started and each other
# member is held by naming the lead, closes with the lead's landing once committed, and goes back
# to the plan on its own when the batch lets it go.
RSpec.describe "a batch of work items" do
  include_context "with new work started"

  let(:hecks) { boot_hecks_in_memory }

  def cli(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv])
    out
  end

  def keys(query) = JSON.parse(cli(query, "work=a")).map { |work| work["work"] }

  def status(key) = JSON.parse(cli("work.undone")).find { |work| work["work"] == key }&.fetch("status") || "done"

  def batch_of_three
    %w[a b c].each { |key| cli("work.plan!", "work.value=#{key}", "title.value=#{key.upcase}") }
    cli("work.start!", "to=a", "claimed_by.value=s", "claimed_at.value=2026-11-19T09:00:00Z")
    %w[b c].each { |key| cli("work.enlist!", "to=#{key}", "batch.value=a") }
  end

  def commit_b = cli("work.commit!", "to=b", "batch_commit.value=abc123")

  it "holds a planned member by naming its lead" do
    batch_of_three

    expect(keys("work.batch_of")).to eq(%w[b c])
  end

  it "closes a committed member with its lead's landing and lets the other go", :aggregate_failures do
    batch_of_three
    commit_b
    cli("work.close!", "to=a", "landing.value=def456")

    expect([status("b"), status("c")]).to eq(%w[done planned])
    expect(keys("work.batch_of")).to be_empty
  end

  it "keeps a committed member with a lead that yields and lets the others go", :aggregate_failures do
    batch_of_three
    commit_b
    cli("work.yield!", "to=a", "reason.value=load", "yield_kind.value=load")

    expect(keys("work.batch_of")).to eq(%w[b])
    expect(keys("work.uncommitted_in")).to be_empty
  end

  it "lets one member leave and keeps the rest" do
    batch_of_three
    cli("work.leave!", "to=b", "reason.value=architect: rethink")

    expect(keys("work.batch_of")).to eq(%w[c])
  end

  it "refuses to hold a started work item in a batch" do
    batch_of_three

    expect(cli("work.enlist!", "to=a", "batch.value=b")).to include("only a planned work item is held in a batch")
  end
end
