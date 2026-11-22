require "spec_helper"

# A work item names the work items it waits on one key at a time: a comma-joined value is refused,
# a key a work item has is stored, and a key no work item has holds the item, naming the key and
# the nearest real keys. Each example boots its own Memory domain.
require_relative "support/new_work_started"

RSpec.describe "Work wait keys" do
  include_context "with new work started"

  let(:hecks) { boot_hecks_in_memory }

  def cli(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv])
    out
  end

  def plan(key) = cli("work.plan!", "work.value=#{key}", "title.value=Step #{key}")

  def row(key)
    aggregate = hecks.registry.bluebook("Tickets").aggregate("Work")
    hecks.registry.repository("Tickets", aggregate).all.find { |item| field(item, :work) == key }
  end

  def field(record, name) = Hecks::Adapters::StartedWork.value(record, name)

  def wait_on(key, *targets) = cli("work.wait_on!", "to=#{key}", *targets.map { |target| "waits_on.value=#{target}" })

  before { %w[wk/a wk/b wk/c].each { |key| plan(key) } }

  it "stores a key a work item has", :aggregate_failures do
    wait_on("wk/a", "wk/b")

    expect(field(row("wk/a"), :waits_on).map { |key| key[:value] }).to eq(["wk/b"])
    expect(field(row("wk/a"), :held_reason).to_s).to eq("")
  end

  it "holds an item that waits on a key no work item has, naming the key and the nearest" do
    wait_on("wk/a", "wk/bb")

    expect(field(row("wk/a"), :held_reason)).to include("wk/bb", "nearest", "wk/b")
  end

  it "refuses a comma-joined value, one key at a time" do
    expect(wait_on("wk/a", "wk/b,wk/c")).to include("one key at a time")
  end
end
