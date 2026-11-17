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

  # The committed world only: the owner's local settings (a load limit raised on the Settings page,
  # say) must not change what this reads, or the spec fails on the owner's machine alone.
  def committed(root, load)
    Hecks::Adapters::FolderOverlay.committed_only { described_class.from_world(root, load: -> { load }).call(20) }
  end

  it "reads the cap from the checkout's committed world" do
    expect(committed(Hecks::RustBuild::ROOT, 0.0)).to eq(4)
  end

  it "reads the limit from the checkout's committed world" do
    expect(committed(Hecks::RustBuild::ROOT, 10.0)).to eq(1)
  end
end
