require "spec_helper"
require_relative "support/sweeping_fixtures"

RSpec.describe Hecks::Adapters::Sweeping, "#sweep proof" do
  include_context "with a sweep fixture"

  it "keeps a host whose start does not match the log's spawn of that pid" do
    log(spawned(100, 90_000), claimed("aaaaaaaa"))
    adapter.sweep(removed: "aaaaaaaa")
    expect(killed).to be_empty
  end

  it "stops no spare when it names no session id" do
    traced_log
    adapter.sweep(removed: "not-an-id")
    expect(killed).to be_empty
  end
end
