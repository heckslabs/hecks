require "spec_helper"
require_relative "support/registry_double"
require "hecks/hecks/adapters/landed_work"

# The LandedWork port's adapter, asked by the worktree a branch landed from: the open work item
# the worktree is named for, when the branch itself names none.
RSpec.describe Hecks::Adapters::LandedWork do
  include RegistryDouble

  def finds(branch, checkout, *items)
    registry = registry_double
    allow(registry).to receive(:repository).and_return(Struct.new(:all).new(items))
    allow(Hecks::Adapters::StartedWork).to receive(:work_aggregate).and_return(Object.new)
    described_class.new(registry: registry)
                   .find_landed_work_by_checkout(branch: { value: branch }, checkout: { value: checkout })
  end

  def item(key, status = "started") = { work: key, status: status }

  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  it "finds the open work item the worktree is named for when the branch is named otherwise" do
    expect(finds("beat-clearance", "/r/.claude/worktrees/the-item", item("the-item"))).to eq(branch: { value: "the-item" })
  end

  it "leaves a branch that names an open work item to the lookup by name" do
    expect { finds("x", "/r/.claude/worktrees/the-item", item("x"), item("the-item")) }
      .to raise_error(failure, /names an open work item/)
  end

  it "refuses by name when the worktree names no open work item" do
    expect { finds("b", "/r/.claude/worktrees/gone", item("gone", "done")) }
      .to raise_error(failure, /no open work item is named gone/)
  end
end
