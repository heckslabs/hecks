require "spec_helper"
require_relative "support/registry_double"
require "hecks/hecks/adapters/landed_work"

# The LandedWork port's adapter when `LinkedTree.add!` suffixed a taken branch name: `x-2` was cut
# for `x`, unless a work item of that whole name exists.
RSpec.describe Hecks::Adapters::LandedWork, "#find_landed_work with a suffix" do
  include RegistryDouble

  def finds(branch, *items)
    registry = registry_double
    allow(registry).to receive(:repository).and_return(Struct.new(:all).new(items))
    allow(Hecks::Adapters::StartedWork).to receive(:work_aggregate).and_return(Object.new)
    described_class.new(registry: registry).find_landed_work(branch: { value: branch })
  end

  def item(key, status = "planned") = { work: key, status: status }

  it "finds the work item a suffixed branch was cut for" do
    expect(finds("x-2", item("x"))).to eq(branch: { value: "x" })
  end

  it "finds it through qa/ and the suffix together" do
    expect(finds("qa/x-3", item("x"))).to eq(branch: { value: "x" })
  end

  it "does not read x-2 as x when x-2 is a work item of its own" do
    expect { finds("x-2", item("x"), item("x-2", "done")) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure)
  end

  it "finds a work item that is itself named with a number" do
    expect(finds("phase-2", item("phase-2"), item("phase"))).to eq(branch: { value: "phase-2" })
  end
end
