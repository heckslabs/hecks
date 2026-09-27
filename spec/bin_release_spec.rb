require "open3"
require "rbconfig"

# bin/release is a thin wrapper over Hecks::Release::Runner (spec/release/
# runner_spec.rb covers the release itself), so this runs it as a real
# subprocess only for the flag handling, which starts no git, gem or npm.
RSpec.describe "bin/release" do
  BIN_RELEASE_SCRIPT = File.join(InMemoryDomain::ROOT, "bin/release").freeze

  def run_release(*args)
    Open3.capture3(RbConfig.ruby, BIN_RELEASE_SCRIPT, *args)
  end

  it "--help prints the usage and exits 0" do
    stdout, _stderr, status = run_release("--help")

    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("Usage: bin/release", "--dry-run", "--gem-only", "--npm-only", "--npm-local", "--no-wait", "--yes")
  end

  it "exits 2 on an unknown flag, printing the usage" do
    _stdout, stderr, status = run_release("--frobnicate")

    expect(status.exitstatus).to eq(2)
    expect(stderr).to include("--frobnicate", "Usage: bin/release")
  end

  it "exits 2 on a stray argument" do
    _stdout, _stderr, status = run_release("2.7.0")

    expect(status.exitstatus).to eq(2)
  end

  it "exits 2 when --gem-only and --npm-only are combined" do
    _stdout, stderr, status = run_release("--gem-only", "--npm-only")

    expect(status.exitstatus).to eq(2)
    expect(stderr).to include("cannot be combined")
  end

  it "exits 2 when --no-wait is combined with --npm-local" do
    _stdout, stderr, status = run_release("--no-wait", "--npm-local")

    expect(status.exitstatus).to eq(2)
    expect(stderr).to include("--no-wait")
  end

  it "exits 2 when --gem-only is combined with --npm-local" do
    _stdout, _stderr, status = run_release("--gem-only", "--npm-local")

    expect(status.exitstatus).to eq(2)
  end
end
