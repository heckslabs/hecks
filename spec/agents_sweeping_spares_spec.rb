require "spec_helper"
require_relative "support/sweeping_fixtures"

# The sweep stops a spare daemon only when the daemon's log traces it to a removed session; the
# readings are a fake shell and a log in a temporary directory.
RSpec.describe Hecks::Adapters::Sweeping, "#sweep spare hosts" do
  include_context "with a sweep fixture"

  before { traced_log }

  it "stops only the host traced to a removed session" do
    adapter(fake_shell(listed: ["bbbbbbbb"])).sweep(removed: { value: "aaaaaaaa" })
    expect(killed).to eq([100])
  end

  it "keeps a host whose session is still listed" do
    adapter(fake_shell(listed: ["aaaaaaaa"])).sweep(removed: "aaaaaaaa")
    expect(killed).to be_empty
  end

  it "keeps every host when the removed session claimed none" do
    adapter.sweep(removed: "cccccccc")
    expect(killed).to be_empty
  end

  it "lists what it would do and stops nothing", :aggregate_failures do
    text = adapter.leftovers(removed: "aaaaaaaa")[:text]
    expect(text).to include("stop  pid 100  aaaaaaaa", "keep  pid 300  untraced")
    expect(killed).to be_empty
  end
end
