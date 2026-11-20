# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/codebase/gate"
require "hecks/hecks/adapters/codebase/tree_facts"

# What the tree-fact specs of a faulted gate read: the GateFaulted payload of one run.
module GateFaultTreeHelpers
  # @return [Hash, nil] the materialized payload of the run's GateFaulted event
  def fault_of(run)
    @hecks.dispatch_flat("Hecks::GateRun.Gate", run: run, stage: "quick")
    event = @hecks.registry.event_log.reverse.find { |held| held.name == "GateFaulted" }
    Hecks::Runtime::Value.materialize(event.payload)
  end

  # The facts the examine answers, as the stubbed git would report a coder's worktree.
  def coder_tree = { linked: { value: true }, branch: { value: "coder-work" } }
end

# A faulted gate run says where it ran, so Tickets can tell a coder's red from main's: the fault
# carries the tree's git facts and the check's name, on a red run and on a tree that is no checkout.
RSpec.describe "a faulted gate run, with the tree it ran in" do
  include GateFaultTreeHelpers

  before(:all) { @hecks = InMemoryDomain.boot_hecks_in_memory }

  before { allow(Hecks::Adapters::Codebase::TreeFacts).to receive(:of).and_return(coder_tree) }

  after { Hecks::Adapters::Codebase::Tree.root = nil }

  it "carries the tree's facts and the check's name on a refused run" do
    allow(Hecks::Adapters::Codebase::Gate).to receive(:call).and_raise(Hecks::Adapters::ConsoleCapture::Failure, "stopped")
    expect(fault_of("tree-red")).to include(coder_tree.merge(check_name: { value: "gate-quick" }))
  end

  it "carries them when the tree is no hecks checkout" do
    Hecks::Adapters::Codebase::Tree.root = Dir.mktmpdir("no-checkout")
    expect(fault_of("tree-none")).to include(coder_tree.merge(check_name: { value: "gate-quick" }))
  end
end
