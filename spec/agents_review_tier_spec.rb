require "spec_helper"
require "hecks/agents/adapters/submitted_paths"

# The review tier of a submitted commit is the Agents bluebook's `ReviewTier` and `SecurityWord`
# rows on ChangeReview, matched by the `SubmittedPaths` adapter to the paths a stand-in git reads.
# No live state: git is a stand-in and the rows are read from the bluebook in this checkout.
RSpec.describe Hecks::Adapters::SubmittedPaths, "#tier" do
  def status = instance_double(Process::Status, success?: true)

  def tier(listing, regenerated: nil)
    git = ->(_argv) { [listing, "", status] }
    described_class.new(git: git).tier(review: "abc1234", checkout: "/co", regenerated: regenerated)[:text]
  end

  def first(listing, **) = tier(listing, **).lines.first.strip

  it "is verify_only for a docs-only change" do
    expect(first("M\tdocs/agents/ci-speed.md\n")).to eq("verify_only")
  end

  it "is verify_only for a refreshed spec list" do
    expect(first("M\t.github/postgres_io_spec_files.txt\n")).to eq("verify_only")
  end

  it "is full for a path no row names" do
    expect(tier("M\tlib/hecks/agents/adapters/x.md\nM\tGemfile\n")).to include("full unnamed Gemfile")
  end

  it "is full when a doc is mixed with an adapter" do
    expect(first("M\tdocs/a.md\nM\tlib/hecks/adapters/clock.rb\n")).to eq("full")
  end

  it "is full for a doc inside an adapters directory, since any full row wins" do
    expect(tier("M\tlib/hecks/agents/adapters/x.md\n").lines.last).to eq("full adapters lib/hecks/agents/adapters/x.md")
  end

  it "is full for a bluebook" do
    expect(first("M\tlib/hecks/agents/agents.bluebook\n")).to eq("full")
  end

  it "is full for the Rust host" do
    expect(tier("M\trust/host/src/main.rs\n")).to include("full rust_host rust/host/src/main.rs")
  end

  it "is full for a golden rewrite whose regeneration was not shown the same" do
    expect(tier("M\tspec/fixtures/deploy_box_golden/a.yml\n")).to start_with("full\nfull golden-unproven")
  end

  it "is verify_only for a golden rewrite that regenerates the same bytes" do
    expect(first("M\tspec/fixtures/deploy_box_golden/a.yml\n", regenerated: { value: "same" })).to eq("verify_only")
  end

  it "is verify_only for a pure rename of plain code" do
    expect(first("R100\tlib/hecks/old_name.rb\tlib/hecks/new_name.rb\n")).to eq("verify_only")
  end

  it "is full for a rename git found edited" do
    expect(first("D\tlib/hecks/old_name.rb\nA\tlib/hecks/new_name.rb\n")).to eq("full")
  end

  it "is full for a pure rename into an adapters directory" do
    expect(first("R100\tlib/hecks/clock.rb\tlib/hecks/adapters/clock.rb\n")).to eq("full")
  end

  it "is full for a security word, even in a docs path" do
    expect(tier("M\tdocs/token-rotation.md\n")).to include("full security docs/token-rotation.md")
  end

  it "matches a security word whole, so keyboard is not key" do
    expect(first("M\tdocs/keyboard_shortcuts.md\n")).to eq("verify_only")
  end

  it "is full for an empty diff, which nothing proves mechanical" do
    expect(first("")).to eq("full")
  end

  it "reads the diff with renames at 100% against main, in the checkout" do
    calls = []
    git = ->(argv) { (calls << argv) && ["", "", status] }
    described_class.new(git: git).tier(review: "abc1234", checkout: { value: "/co" })
    expect(calls).to eq([%w[git -C /co diff --name-status -M100% main...abc1234]])
  end
end
