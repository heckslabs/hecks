require "spec_helper"

# A landing that names a linked worktree by its run id takes that worktree's checkout and branch,
# unless the caller names them. Only a command that lands a branch reads the worktree.
RSpec.describe Hecks::Adapters::Driving::CliRunner::RunReference do
  let(:runtime) { Object.new }
  let(:landing) { { command: "Hecks::Landing.Land" } }
  let(:tree) { { ok: true, record: { path: "/repo/.claude/worktrees/x", branch: "x" } } }

  before { allow(Hecks::Storehouse).to receive(:state).and_return(tree) }

  def named(**values) = values.transform_values { |value| { value: value } }

  describe ".ids" do
    it "names the run, the record written, and the references the command used" do
      ids = described_class.ids(named(run: "r1", from: "ids-1", checkout: "/c", branch: "b"), "rec-1")

      expect(ids).to eq(run: "r1", from: "ids-1", checkout: "/c", branch: "b", id: "rec-1")
    end

    it "leaves out the ids a command did not use" do
      expect(described_class.ids(named(branch: "b"), nil)).to eq(branch: "b")
    end
  end

  describe ".fill" do
    it "takes the checkout and branch of the worktree the run names", :aggregate_failures do
      filled = described_class.fill(runtime, landing, named(from: "ids-1"))

      expect(filled[:checkout]).to eq(value: "/repo/.claude/worktrees/x")
      expect(filled[:branch]).to eq(value: "x")
    end

    it "reads the LinkedTree record the run names" do
      described_class.fill(runtime, landing, named(from: "ids-1"))

      expect(Hecks::Storehouse).to have_received(:state).with(hash_including(aggregate: "LinkedTree", id: "ids-1"))
    end

    it "unwraps a stored word to its value" do
      allow(Hecks::Storehouse).to receive(:state)
        .and_return(ok: true, record: { path: { value: "/p" }, branch: { value: "b" } })

      filled = described_class.fill(runtime, landing, named(from: "ids-1"))

      expect(filled).to include(checkout: { value: "/p" }, branch: { value: "b" })
    end

    it "keeps an explicit checkout and branch over the worktree's", :aggregate_failures do
      filled = described_class.fill(runtime, landing, named(from: "ids-1", checkout: "/mine", branch: "mine"))

      expect(filled[:checkout]).to eq(value: "/mine")
      expect(filled[:branch]).to eq(value: "mine")
    end

    it "leaves the arguments alone when no run is named" do
      described_class.fill(runtime, landing, named(branch: "b"))

      expect(Hecks::Storehouse).not_to have_received(:state)
    end

    it "leaves the arguments alone for a command that does not land a branch" do
      retire = { command: "Hecks::Landing.Retire" }

      expect(described_class.fill(runtime, retire, named(from: "ids-1"))).to eq(named(from: "ids-1"))
    end

    it "leaves the arguments alone when the named worktree is not stored" do
      allow(Hecks::Storehouse).to receive(:state).and_return(ok: false, error: "no LinkedTree found")

      expect(described_class.fill(runtime, landing, named(from: "ids-9"))).to eq(named(from: "ids-9"))
    end
  end
end
