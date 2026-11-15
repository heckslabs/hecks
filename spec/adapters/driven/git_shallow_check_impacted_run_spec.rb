# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "hecks/hecks/adapters/git_shallow_check"

# The impacted-spec run stops at the world's gate budget and returns the specs it left; its
# workers are as many as the world and the load allow, and a red spec refuses by name.
RSpec.describe Hecks::Adapters::GitShallowCheck::ImpactedRun, "#call" do
  let(:ticks) { Queue.new([0, 0, 700, 700]) }
  let(:specs) { %w[spec/a_spec.rb spec/b_spec.rb spec/c_spec.rb] }

  def build(width, clock)
    described_class.new(Dir.pwd, budget: 600, clock: clock, workers: ->(_count) { width }).tap do |run|
      allow(run).to receive(:mapped).and_return(specs)
      allow(run).to receive(:pass!) { |spec, ran, lock| lock.synchronize { ran << spec } }
    end
  end

  it "stops before the next spec once the budget has passed", :aggregate_failures do
    done = build(1, -> { ticks.pop }).call([], "main")
    expect(done.ran).to eq(["spec/a_spec.rb"])
    expect(done.unrun).to eq(%w[spec/b_spec.rb spec/c_spec.rb])
  end

  it "runs every spec with several workers" do
    expect(build(3, -> { 0 }).call([], "main").ran).to match_array(specs)
  end

  it "runs every spec with one worker, in order" do
    expect(build(1, -> { 0 }).call([], "main").ran).to eq(specs)
  end

  it "records what it could not run when the budget is spent first", :aggregate_failures do
    done = build(1, Queue.new([0, *Array.new(8, 700)]).method(:pop)).call([], "main")
    expect(done.ran).to be_empty
    expect(done.unrun).to eq(specs)
  end

  it "raises the first red spec by name" do
    run = build(2, -> { 0 })
    allow(run).to receive(:pass!).and_raise(Hecks::Adapters::ConsoleCapture::Failure, "impacted specs red: x")
    expect { run.call([], "main") }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /red: x/)
  end
end
