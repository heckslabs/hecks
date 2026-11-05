require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/ports/persistence/plugins/era"

# The planner behind `SchemaRevision.Reconcile`: the edge a latest era needs, and which files
# that edge supersedes, and the refusal that names an earlier era the change would strand. Every
# case runs on a temporary directory of edge files and on edges built in memory; no database is
# touched.
RSpec.describe Hecks::Translation::Reconcile do
  around do |example|
    Dir.mktmpdir("reconcile-") do |dir|
      @directory = dir
      example.run
    end
  end

  let(:domain) { "Ledger" }

  def edge(from, to) = Hecks::Bluebook::Translation.new(domain: domain, from: from, to: to)

  # Writes each edge as a file under `translations/`, named as the domain's edge files are.
  def write_edges(edges)
    FileUtils.mkdir_p(File.join(@directory, "translations"))
    edges.each do |found|
      path = Hecks::Translation::EdgeFiles.path_for(@directory, from: found.from, to: found.to)
      File.write(path, %(Hecks.data_translation "#{domain}", from: "#{found.from}", to: "#{found.to}" do\nend\n))
    end
  end

  def scope(held:, current:, edges:, files:)
    Hecks::Translation::Reconcile::Scope.new(domain: domain, held: held, current: current, edges: edges,
                                             files: files, directory: @directory)
  end

  def plan_for(labels, current, edges)
    held = labels.each_with_index.map { |label, index| { ordinal: index + 1, label: label } }
    write_edges(edges)
    files = Hecks::Translation::EdgeFiles.scan(@directory)
    described_class.plan(scope(held: held, current: current, edges: edges, files: files))
  end

  def removed_names(plan) = plan.removals.map { |path| File.basename(path) }.sort

  describe "a domain already on its current shape" do
    subject(:plan) { plan_for(%w[C], "C", []) }

    it "has nothing to write or delete" do
      expect(plan.status).to eq(:clean)
    end

    it "mints nothing on the next boot" do
      expect(plan.mints).to be(false)
    end
  end

  describe "a domain with no era held" do
    it "reports no era and names no edge" do
      plan = described_class.plan(scope(held: [], current: "C", edges: [], files: []))
      expect(plan.status).to eq(:no_era)
    end
  end

  describe "a stale chain" do
    subject(:plan) { plan_for(%w[A L], "C", [edge("A", "L"), edge("L", "I"), edge("I", "C")]) }

    it "composes the chain into one edge from the latest era to the current shape" do
      expect([plan.status, plan.edge.from, plan.edge.to]).to eq([:write, "L", "C"])
    end

    it "removes the intermediate edges the chain used, and keeps the earlier era's edge" do
      expect(removed_names(plan)).to eq(["2-I-to-C.bluebook", "2-L-to-I.bluebook"])
    end
  end

  describe "a fork whose branch is covered" do
    subject(:plan) { plan_for(%w[D L], "C", [edge("D", "L"), edge("L", "C"), edge("L", "D")]) }

    it "removes only the superseded branch" do
      expect(removed_names(plan)).to eq(["2-L-to-D.bluebook"])
    end

    it "writes no new edge, since the one that leads to the current shape already stands" do
      expect([plan.status, plan.edge]).to eq([:write, nil])
    end
  end

  describe "an earlier era the change would strand" do
    subject(:plan) { plan_for(%w[X L], "C", [edge("X", "I"), edge("L", "I"), edge("I", "C")]) }

    it "refuses by naming the era, and writes nothing" do
      expect(plan.refusal).to include("the change would leave era 1 (X) a way to C")
    end

    it "is refused as a whole" do
      expect(plan.status).to eq(:refused)
    end
  end

  describe "an earlier era still using an edge the change deletes" do
    subject(:plan) { plan_for(%w[I L], "C", [edge("L", "I"), edge("I", "C")]) }

    it "refuses by naming the era and the edge it still uses" do
      expect(plan.refusal).to include("era 1 (I) still uses the edge I -> C")
    end
  end

  describe "a latest era with no edge to the current shape" do
    subject(:plan) { plan_for(%w[A], "B", []) }

    it "refuses, naming the two shapes" do
      expect(plan.refusal).to eq("no translation edge leads A to B")
    end
  end

  describe "running the change twice" do
    let(:first) { plan_for(%w[A L], "C", [edge("A", "L"), edge("L", "I"), edge("I", "C")]) }

    it "finds nothing to do the second time" do
      Hecks::Translation::ReconcileFiles.write!(first)
      after = [edge("A", "L"), edge("L", "C")]
      expect(plan_for(%w[A L], "C", after).status).to eq(:clean)
    end
  end
end
