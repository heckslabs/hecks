# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "hecks/hecks/adapters/git_shallow_check"

# The landing's impacted-spec workers: the world's cap, held to the room under the fill's limit.
RSpec.describe Hecks::Adapters::GitShallowCheck::ImpactedWorkers do
  def workers(load, specs: 20, cap: 4) = described_class.count(specs: specs, cap: cap, load: load, limit: 10.0)

  it "runs one at a time with the load at the limit" do
    expect(workers(10.0)).to eq(1)
  end

  it "runs one at a time with the load over the limit" do
    expect(workers(16.6)).to eq(1)
  end

  it "runs up to the cap on an idle machine" do
    expect(workers(0.5)).to eq(4)
  end

  it "holds the workers to the room the load leaves" do
    expect(workers(7.5)).to eq(2)
  end

  it "never starts more workers than specs" do
    expect(workers(0.0, specs: 2)).to eq(2)
  end

  it "reads the cap and the limit from the checkout's world", :aggregate_failures do
    root = Hecks::RustBuild::ROOT
    expect(described_class.from_world(root, load: -> { 0.0 }).call(20)).to eq(4)
    expect(described_class.from_world(root, load: -> { 10.0 }).call(20)).to eq(1)
  end
end
