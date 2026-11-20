require "spec_helper"
require "json"
require_relative "support/new_work_started"
require "hecks/hecks/adapters/dispatching"

# A group batch is one coder session for several work items: its lead is started and each other
# member is batched under the lead, closes with the lead's landing, stays with a lead that yields
# once committed, and goes back to the plan on its own when the batch lets it go.
RSpec.describe "a batch of work items" do
  include_context "with new work started"

  let(:hecks) { boot_hecks_in_memory }

  def cli(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv])
    out
  end

  def keys(query) = JSON.parse(cli(query, "work=a")).map { |work| work["work"] }.sort

  def status(key) = JSON.parse(cli("work.undone")).find { |work| work["work"] == key }&.fetch("status") || "done"

  def batch_of_three
    %w[a b c].each { |key| cli("work.plan!", "work.value=#{key}", "title.value=#{key.upcase}") }
    cli("work.start!", "to=a", "claimed_by.value=s", "claimed_at.value=2026-11-19T09:00:00Z")
    %w[b c].each { |key| cli("work.enlist!", "to=#{key}", "batch.value=a") }
  end

  def commit_b = cli("work.commit!", "to=b", "batch_commit.value=abc123")

  it "takes each member out of the plan into its lead's batch", :aggregate_failures do
    batch_of_three

    expect(keys("work.in_batch")).to eq(%w[b c])
    expect(status("b")).to eq("batched")
  end

  it "closes the members with their lead's landing" do
    batch_of_three
    commit_b
    cli("work.close!", "to=a", "landing.value=def456")

    expect([status("b"), status("c")]).to eq(%w[done done])
  end

  it "keeps a committed member with a lead that yields and returns the others", :aggregate_failures do
    batch_of_three
    commit_b
    cli("work.yield!", "to=a", "reason.value=load", "yield_kind.value=load")

    expect(keys("work.in_batch")).to eq(%w[b])
    expect(status("c")).to eq("planned")
  end

  it "returns one member to the plan and keeps the rest" do
    batch_of_three
    cli("work.return!", "to=b", "reason.value=architect: rethink")

    expect(keys("work.in_batch")).to eq(%w[c])
  end

  it "refuses to record a commit for a work item in no batch" do
    batch_of_three

    expect(cli("work.commit!", "to=a", "batch_commit.value=abc123")).to include("only a batched work item is committed")
  end

  it "reads a started lead for the fill with the members waiting in its batch" do
    batch_of_three
    lead = Hecks::Adapters::Dispatching::WorkItems.new(hecks.registry).started.find { |item| item.key == "a" }

    expect(lead.batched.map(&:key).sort).to eq(%w[b c])
  end
end
