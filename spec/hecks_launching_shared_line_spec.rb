require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# Reads the coordination lines a fill would brief the chosen work item at `index` with.
class LaunchingLinesHost
  include Hecks::Adapters::Dispatching::Launching

  attr_reader :work_items

  def initialize(started) = @work_items = Struct.new(:started, :runs).new(started, {})

  def lines(plan, index) = holding(plan, index)
end

# A work item started beside one that holds other sections of the same bluebook is briefed with a
# coordination line that names the file they share and the sections it must leave alone.
RSpec.describe Hecks::Adapters::Dispatching::Launching do
  def item(key, area) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: "t #{key}", area: area)

  let(:started) { [item("adds-b", ["s.bluebook#B"]), item("docs", ["docs"])] }
  let(:plan) { Struct.new(:chosen).new([item("adds-c", ["s.bluebook#C"])]) }

  it "tells the newcomer in its coordination lines which file it shares and what the other holds" do
    expect(LaunchingLinesHost.new(started).lines(plan, 0)).to eq(
      ["adds-b: t adds-b (s.bluebook#B); shares s.bluebook with you: it holds B, edit only your own sections of it",
       "docs: t docs (docs)"]
    )
  end
end
