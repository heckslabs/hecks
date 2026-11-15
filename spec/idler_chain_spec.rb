require "spec_helper"
require_relative "support/idler_chain"

# Planned work that a roll held back is rolled again by one idle chain, with no train boarded: the
# chain starts from the roll's own answer, and one record per store allows one chain at a time.
RSpec.describe "the idle chain that starts when a roll holds work back" do
  include IdlerChain

  before { @hecks = boot_hecks_in_memory }

  it "starts one chain that watches no branch", :aggregate_failures do
    answer_roll("held-a", 1)
    expect(started.size).to eq(1)
    expect(started.first.first).to include("HECKS_TICK_AGGREGATE" => "Idler")
    expect(started.first.first).not_to have_key("HECKS_TICK_WATCH")
  end

  it "starts no second chain while one stands" do
    answer_roll("held-b", 1)
    answer_roll("held-c", 1)
    expect(started.size).to eq(1)
  end

  it "starts no chain when a roll holds nothing back" do
    answer_roll("clear-d", 0)
    expect(started).to be_empty
  end

  it "starts a new chain after the last one ended" do
    answer_roll("held-e", 1)
    dispatch("Idler.Stop", idler: "idle", ending: { value: "over" })
    answer_roll("held-f", 1)
    expect(started.size).to eq(2)
  end
end
