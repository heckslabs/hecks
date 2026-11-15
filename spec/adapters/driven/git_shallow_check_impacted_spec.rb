# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "hecks/hecks/adapters/git_shallow_check"
require_relative "../../support/shallow_repo"

# What a landing's impacted-spec run answers, handed to the adapter in place of the launcher.
module ImpactedStandIn
  RUN = Hecks::Adapters::GitShallowCheck::ImpactedRun

  # @param red [String, nil] the failure the run raises
  # @return [#call] answers an outcome of `ran`, `unrun` and `seconds`, or raises `red`
  def impacted(ran: [], unrun: [], seconds: 3, red: nil)
    lambda do |_paths, _onto|
      raise Hecks::Adapters::ConsoleCapture::Failure, red if red

      RUN::Outcome.new(ran, unrun, seconds)
    end
  end

  def landing(**done)
    build_repo("docs/guide.md")
    shallow(command: ["false"], impacted: impacted(**done))
  end
end

# A landing runs the specs its changes touch inside the world's `impacted_seconds`.
RSpec.describe Hecks::Adapters::GitShallowCheck, "#shallow_check impacted specs" do
  include ShallowRepo
  include ImpactedStandIn

  it "refuses a landing whose impacted spec is red, naming the spec" do
    red = "impacted specs red: failing spec: ./spec/ir_golden_spec.rb:9"
    expect { landing(red: red) }.to raise_error(failure, %r{failing spec: \./spec/ir_golden_spec\.rb:9})
  end

  it "reports what ran when the budget held", :aggregate_failures do
    answer = landing(ran: ["spec/a_spec.rb"])
    expect(answer[:report][:value]).to include("impacted specs: 1 ran in 3 s")
    expect(answer).not_to have_key(:unrun)
  end

  it "lands an overrun and names the unrun specs and the seconds spent" do
    answer = landing(unrun: %w[spec/a_spec.rb spec/b_spec.rb], seconds: 601)
    expect(answer[:unrun][:value]).to eq("spec/a_spec.rb spec/b_spec.rb (not run: 601 s spent of the budget)")
  end
end
