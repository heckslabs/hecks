require "spec_helper"
require_relative "support/registry_double"
require "hecks/hecks/adapters/landed_work"

# The LandedWork port's adapter against a stubbed Work repository: which open row a branch names.
RSpec.describe Hecks::Adapters::LandedWork do
  include RegistryDouble

  def finds(branch, *rows)
    registry = registry_double
    allow(registry).to receive(:repository).and_return(Struct.new(:all).new(rows))
    allow(Hecks::Adapters::StartedWork).to receive(:work_aggregate).and_return(Object.new)
    described_class.new(registry: registry).find_landed_work(branch: { value: branch })
  end

  def row(key, status = "planned") = { work: key, status: status }

  it "finds the row of the whole branch name before the stripped one" do
    expect(finds("qa/x", row("x"), row("qa/x"))).to eq(branch: { value: "qa/x" })
  end

  it "finds the row of the name without qa/" do
    expect(finds("qa/x", row("x", "started"))).to eq(branch: { value: "x" })
  end

  it "refuses by name when no open row is named" do
    expect { finds("qa/x", row("y")) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, %r{no open step is named qa/x})
  end

  it "does not find a row that is done" do
    expect { finds("x", row("x", "done")) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure)
  end
end
