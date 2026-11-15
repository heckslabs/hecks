# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "hecks/hecks/adapters/git_shallow_check"

# The impacted-spec run stops at the world's gate budget and returns the specs it left.
RSpec.describe Hecks::Adapters::GitShallowCheck::ImpactedRun, "#call" do
  let(:ticks) { [0, 0, 700, 700].each }
  let(:run)   { described_class.new(Dir.pwd, budget: 600, clock: -> { ticks.next }) }

  before do
    allow(run).to receive(:mapped).and_return(%w[spec/a_spec.rb spec/b_spec.rb])
    allow(run).to receive(:pass!) { |spec, ran| ran << spec }
  end

  it "stops before the next spec once the budget has passed", :aggregate_failures do
    done = run.call([], "main")
    expect(done.ran).to eq(["spec/a_spec.rb"])
    expect(done.unrun).to eq(["spec/b_spec.rb"])
  end
end
