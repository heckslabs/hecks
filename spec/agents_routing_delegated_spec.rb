require "spec_helper"
require_relative "support/routing_reads_helper"

# The guard binds the Lead's own session, never a subagent that only uses its agent file.
RSpec.describe "the Lead guard and a delegated run" do
  include RoutingReadsHelper

  it "refuses a Lead-session command off the list" do
    expect(refusal("cat lib/x.rb")).to include("routes only")
  end

  it "allows the same command from a delegated run" do
    expect(verdict("cat lib/x.rb", agent: { value: "a1" })).to eq(text: "allowed")
  end

  it "binds the session when the agent id is blank" do
    expect(refusal("cat lib/x.rb", agent: { value: "" })).to include("routes only")
  end
end
