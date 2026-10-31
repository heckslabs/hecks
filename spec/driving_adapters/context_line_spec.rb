require "spec_helper"
require "stringio"

RSpec.describe Hecks::Adapters::Driving::ContextLine do
  let(:stores) do
    [["store Hecks", "Memory", "hecksagon"],
     ["store Tickets", "SqliteAt /x/tickets.db", "world"],
     ["store Tickets::Work", "SqliteAt /x/tickets.db", "aggregate bind"]]
  end

  it "names the checkout, the stores off Memory, and the audience" do
    text = described_class.line(directory: "/tmp/hecks", stores: stores, audience: "maintainer")
    expect(text).to eq("checkout hecks (detached) · Tickets in SQLite · audience maintainer")
  end

  it "says Memory when every bluebook stores in memory" do
    expect(described_class.stored([["store Hecks", "Memory", "hecksagon"]])).to eq("Memory")
  end

  it "prints nothing when the error stream is not a terminal" do
    expect(described_class.announce(StringIO.new, directory: "/tmp/hecks")).to be_nil
  end
end
