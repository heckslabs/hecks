require "spec_helper"
require "tmpdir"
require "hecks/rust_build"

# The Tickets world's `rust_build` line caps the jobs and sets the `nice` of every build hecks
# starts; a checkout with no such line is left as it was.
RSpec.describe Hecks::RustBuild::BuildPolicy do
  let(:session) { Hecks::RustBuild::SessionBuild }
  let(:root) { "/some/checkout" }

  def declare(**row)
    allow(session).to receive(:world_row).with(root, "rust_build").and_return(row)
  end

  it "reads the committed Tickets world of this checkout", :aggregate_failures do
    expect(described_class.jobs(Hecks::RustBuild::ROOT)).to eq(4)
    expect(described_class.nice(Hecks::RustBuild::ROOT)).to eq(15)
  end

  it "caps the Cargo jobs at the line's number" do
    declare(jobs: 3, nice: 10)

    expect(described_class.environment(root: root, base: {})).to eq("CARGO_BUILD_JOBS" => "3")
  end

  it "takes a third of the cores, and at least two, when the line names no jobs", :aggregate_failures do
    declare(nice: 10)

    expect(described_class.jobs(root, cores: 12)).to eq(4)
    expect(described_class.jobs(root, cores: 2)).to eq(2)
  end

  it "leaves a job count set by hand alone" do
    declare(jobs: 3)

    expect(described_class.environment(root: root, base: { "CARGO_BUILD_JOBS" => "9" })).to eq({})
  end

  it "asks nothing of a checkout that declares no line", :aggregate_failures do
    declare

    expect(described_class.environment(root: root, base: {})).to eq({})
    expect(described_class.nice(root)).to be_nil
  end

  it "puts `nice` in front of every build command, a worktree or not" do
    declare(jobs: 4, nice: 15)

    expect(session.command(%w[cargo build], root: root)).to eq(%w[nice -n 15 cargo build])
  end

  it "keeps its files under HECKS_CACHE_DIR when the environment names one", :aggregate_failures do
    expect(described_class.cache_root(base: { "HECKS_CACHE_DIR" => "/tmp/x" })).to eq("/tmp/x/rust-build")
    expect(described_class.cache_root(base: {})).to end_with("/rust-build")
  end
end
