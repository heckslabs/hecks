require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/landing_claims_registry"

# A work item's area is the files its branch edits once it has commits, not the directory it was
# planned with; two work items that edit one file still wait for each other.
RSpec.describe Hecks::Adapters::Dispatching::EffectiveArea do
  let(:plan_class) { Hecks::Adapters::Dispatching::Plan }
  let(:shell) { Hecks::Adapters::Shell.new }
  let(:repo) { Dir.mktmpdir("effective-area") }

  after { FileUtils.remove_entry(repo) }

  def git(*argv) = shell.capture("git", "-c", "user.name=t", "-c", "user.email=t@t", *argv, chdir: repo)

  def commit_files(*paths)
    paths.each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(repo, path)))
      File.write(File.join(repo, path), "#{path}\n")
    end
    git("add", ".")
    git("commit", "-q", "-m", "change")
  end

  def landing_branch(name, *paths)
    git("checkout", "-q", "-b", name)
    commit_files(*paths)
    git("checkout", "-q", "main")
  end

  def branch_editing(name, *paths)
    git("init", "-q", "-b", "main")
    commit_files("README.md")
    git("checkout", "-q", "-b", name)
    commit_files(*paths)
    git("checkout", "-q", "main")
  end

  # What `Rivals` calls: a git that takes its arguments without the program name.
  def git_adapter
    shell = self.shell
    Object.new.tap { |adapter| adapter.define_singleton_method(:capture) { |*argv, **opts| shell.capture("git", *argv, **opts) } }
  end

  def item(key, area) = plan_class::Item.new(key: key, title: key, detail: "", area: area)

  def refusal(landing, held)
    allow(Hecks::Adapters::StartedWork).to receive(:items).and_return([{ key: "held", area: held }])
    bound = LandingClaimsRegistry.landing_claims_registry
    Hecks::Adapters::GitLanding::Rivals.new(git_adapter, repo, bound).refusal(landing, "main")
  end

  def narrowed
    branch_editing("held", "lib/hecks/hecks/adapters/a.rb", "lib/hecks/hecks/adapters/b.rb")
    described_class.new(repo).call(item("held", ["lib/hecks/hecks/adapters"]))
  end

  it "holds the files its branch changes, and lets go of the directory" do
    expect(narrowed).to eq(%w[lib/hecks/hecks/adapters/a.rb lib/hecks/hecks/adapters/b.rb])
  end

  it "keeps a file the plan named and the planned area before any commit", :aggregate_failures do
    expect(described_class.choose(%w[lib/x lib/y.rb], %w[lib/z.rb])).to eq(%w[lib/y.rb lib/z.rb])
    expect(described_class.choose(%w[lib/x], [])).to eq(%w[lib/x])
  end

  it "holds the planned area when the branch does not exist" do
    branch_editing("other", "lib/o.rb")
    expect(described_class.new(repo).call(item("none", ["lib"]))).to eq(["lib"])
  end

  it "does not refuse a landing of a third file in the directory" do
    held = narrowed
    landing_branch("third", "lib/hecks/hecks/adapters/c.rb")

    expect(refusal("third", held)).to be_nil
  end

  it "refuses a landing of one of the two files" do
    held = narrowed
    landing_branch("same", "lib/hecks/hecks/adapters/b.rb")

    expect(refusal("same", held)).to include("lib/hecks/hecks/adapters/b.rb")
  end

  describe "in the fill" do
    def plan(effective)
      plan_class.new([item("later", ["lib/hecks/hecks/adapters/c.rb"])], [item("held", ["lib/hecks/hecks/adapters"])],
                     cap: 5, load: 0.5, max_load: 10.0, frozen: [], effective: effective)
    end

    it "starts an item the directory claim would have skipped" do
      expect(plan(->(entry) { entry.key == "held" ? %w[lib/hecks/hecks/adapters/a.rb] : entry.area }).chosen.map(&:key))
        .to eq(["later"])
    end

    it "still holds an item that edits the same file", :aggregate_failures do
      same = ->(entry) { entry.key == "held" ? %w[lib/hecks/hecks/adapters/c.rb] : entry.area }

      expect(plan(same).chosen).to be_empty
      expect(plan(nil).skipped.map(&:reason).first).to include("overlaps held")
    end
  end

  describe Hecks::Adapters::Dispatching::PackageRoots do
    it "names a package directory a work item claims, with the list", :aggregate_failures do
      line = described_class.warning(item("w", ["lib/hecks/", "lib/x.rb"]))

      expect(line).to include("w claims lib/hecks/", "lib/hecks/hecks")
      expect(described_class.warning(item("w", ["lib/hecks/hecks/adapters"]))).to be_nil
    end
  end
end
