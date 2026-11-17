# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "hecks/hecks/adapters/git_shallow_check"
require_relative "../../support/shallow_repo"

# While the off marker stands, a landing's shallow check answers at once, before it takes the
# checkout's claim or a heavy-job place, and runs no spec: main's own verification runs them.
RSpec.describe Hecks::Adapters::GitShallowCheck, "#shallow_check while off" do
  include ShallowRepo

  let(:claimed) { [] }
  let(:slotted) { [] }
  let(:ran) { [] }

  def spy_claim
    seen = claimed
    Class.new do
      define_method(:hold) do |*_args, &block|
        seen << :claim
        [block.call, ""]
      end
    end.new
  end

  def spy_slots
    lambda do |_root, _job, &block|
      slotted << :slot
      [block.call, ""]
    end
  end

  def spy_impacted
    outcome = Hecks::Adapters::GitShallowCheck::ImpactedRun::Outcome.new([], [], 0, 0)
    lambda do |_paths, _onto|
      ran << :specs
      outcome
    end
  end

  def checked(**tune) = shallow(command: ["false"], claim: spy_claim, slots: spy_slots, impacted: spy_impacted, **tune)

  before { build_repo("lib/a.rb") }

  it "says the check is off" do
    switch("off")
    expect(checked[:report][:value]).to eq("shallow check is off")
  end

  it "takes no claim" do
    switch("off")
    checked
    expect(claimed).to be_empty
  end

  it "takes no heavy-job place" do
    switch("off")
    checked
    expect(slotted).to be_empty
  end

  it "runs no impacted spec" do
    switch("off")
    checked
    expect(ran).to be_empty
  end

  it "takes the claim and a place, and runs the specs, once the marker is gone", :aggregate_failures do
    switch("off")
    switch("on")
    shallow(command: ["true"], specs: [], claim: spy_claim, slots: spy_slots, impacted: spy_impacted)
    expect([claimed, slotted, ran]).to eq([[:claim], [:slot], [:specs]])
  end
end
