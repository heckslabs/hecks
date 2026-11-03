require "spec_helper"
require_relative "support/registry_double"
require "hecks/hecks/adapters/landed_work"

# The LandedWork port's adapter against a stubbed Work repository: which open work item a branch
# names.
RSpec.describe Hecks::Adapters::LandedWork do
  include RegistryDouble

  def finds(branch, *items)
    registry = registry_double
    allow(registry).to receive(:repository).and_return(Struct.new(:all).new(items))
    allow(Hecks::Adapters::StartedWork).to receive(:work_aggregate).and_return(Object.new)
    described_class.new(registry: registry).find_landed_work(branch: { value: branch })
  end

  def item(key, status = "planned") = { work: key, status: status }

  it "finds the work item of the whole branch name before the stripped one" do
    expect(finds("qa/x", item("x"), item("qa/x"))).to eq(branch: { value: "qa/x" })
  end

  it "finds the work item of the name without qa/" do
    expect(finds("qa/x", item("x", "started"))).to eq(branch: { value: "x" })
  end

  it "refuses by name when no open work item is named" do
    expect do
      finds("qa/x", item("y"))
    end.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, %r{no open work item is named qa/x})
  end

  it "does not find a work item that is done" do
    expect { finds("x", item("x", "done")) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure)
  end
end
