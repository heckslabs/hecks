require "spec_helper"
require "hecks/agents/adapters/routing_guard"

# The launcher holds the crew to the guards its accepted agreements name: an accepted agreement
# whose guard resolves to no policy refuses the session's calls until it is re-enforced.
RSpec.describe "the launcher enforcing the accepted agreements' guards" do
  let(:rows)     { ->(table) { table == "RoutingRule" ? [{ role: "coder", pattern: "*" }] : [] } }
  let(:policies) { ["Pipeline:HoldEveryPushedWhenMainRed"] }
  let(:guards)   { { "WA-G1" => "Pipeline:HoldEveryPushedWhenMainRed" } }
  let(:settings) { { rows: rows, scripts: nil, agreements: -> { guards }, policies: -> { policies } } }
  let(:guard)    { Hecks::Adapters::RoutingGuard.new(settings: settings) }

  def ask(command) = guard.guard(role: { value: "coder" }, command: { value: command })

  def refusal(command)
    ask(command)
    nil
  rescue Hecks::Adapters::RoutingGuard::Refused => e
    e.message
  end

  it "lets a call through when every accepted guard resolves" do
    expect(ask("exe/hecks Work.undone")).to eq(text: "allowed")
  end

  context "when an accepted agreement's guard resolves to no policy" do
    let(:guards) { { "WA-G1" => "Pipeline:HoldNothingAtAll" } }

    it "refuses the call naming the agreement and its guard" do
      expect(refusal("exe/hecks Work.undone")).to include("WA-G1", "Pipeline:HoldNothingAtAll")
    end

    it "still lets the agreement be enforced again" do
      expect(refusal("exe/hecks Agreement.enforce! reference=WA-G1")).to be_nil
    end
  end

  context "when the agreement store cannot be read" do
    let(:settings) { super().merge(agreements: -> { raise "store unreadable" }) }

    it "warns and allows the call" do
      expect { expect(ask("exe/hecks Work.undone")).to eq(text: "allowed") }.to output(/could not answer/).to_stderr
    end
  end
end
