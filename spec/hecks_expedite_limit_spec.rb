require "spec_helper"
require_relative "support/new_work_started"

# The priority lane holds at most two planned or started work items. A third `Work.expedite!` is
# put back to priority `now` and the item says which two hold the lane; a place freed by a finished
# item lets the next item in. Expediting a holder again changes nothing.
RSpec.describe "the priority lane holds at most two items" do
  include_context "with new work started"

  let(:hecks) { boot_hecks_in_memory }

  def cli(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv])
    out
  end

  def item(key) = JSON.parse(cli("work.undone")).find { |work| work["work"] == key }

  def expedite(key)
    cli("work.plan!", "work.value=#{key}", "title.value=Step #{key}")
    cli("work.expedite!", "to=#{key}")
  end

  def priority(key) = item(key)["priority"].then { |value| value.is_a?(Hash) ? value["value"] : value }

  it "puts a third expedited item back and names the two that hold the lane", :aggregate_failures do
    %w[hot-1 hot-2 hot-3].each { |key| expedite(key) }

    expect(priority("hot-3")).to eq("now")
    expect(item("hot-3").to_s).to include("hot-1", "hot-2")
  end

  it "keeps the two holders expedited" do
    %w[hot-1 hot-2 hot-3].each { |key| expedite(key) }

    expect(%w[hot-1 hot-2].map { |key| priority(key) }).to eq(%w[expedite expedite])
  end

  it "accepts the third once one of the two is closed" do
    %w[hot-1 hot-2].each { |key| expedite(key) }
    cli("work.close!", "to=hot-1", "no_change.value=a verify")
    expedite("hot-3")

    expect(priority("hot-3")).to eq("expedite")
  end

  it "lets a holder be expedited again while the lane is full" do
    %w[hot-1 hot-2].each { |key| expedite(key) }
    cli("work.expedite!", "to=hot-1")

    expect(priority("hot-1")).to eq("expedite")
  end

  it "does not put a refused item back into the lane when a place frees later", :aggregate_failures do
    %w[hot-1 hot-2 hot-3].each { |key| expedite(key) }
    cli("work.close!", "to=hot-1", "no_change.value=a verify")

    expect(priority("hot-3")).to eq("now")
  end
end
