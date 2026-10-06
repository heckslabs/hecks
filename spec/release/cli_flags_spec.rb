require "open3"
require "rbconfig"

# `hecks publish` is `Hecks::CLI::Release` over Hecks::Release::Runner (spec/release/
# runner_spec.rb covers the release itself), so this runs the library entry point as a real
# subprocess only for the flag handling, which starts no git, gem or npm.
RSpec.describe "Hecks::CLI::Release flags" do
  # The child's whole program: the library entry point, given the checkout root.
  RELEASE_CHILD = '$LOAD_PATH.unshift("lib"); require "hecks/cli/release"; ' \
                  "exit(Hecks::CLI::Release.call(ARGV, root: Dir.pwd))".freeze

  def run_release(*args)
    Open3.capture3(RbConfig.ruby, "-e", RELEASE_CHILD, "--", *args, chdir: InMemoryDomain::ROOT)
  end

  it "--help prints the usage and exits 0", :aggregate_failures do
    stdout, _stderr, status = run_release("--help")

    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("Usage:", "--dry-run", "--gem-only", "--npm-only", "--npm-local", "--no-wait", "--yes")
  end

  it "exits 2 on an unknown flag, printing the usage", :aggregate_failures do
    _stdout, stderr, status = run_release("--frobnicate")

    expect(status.exitstatus).to eq(2)
    expect(stderr).to include("--frobnicate", "Usage:")
  end

  it "exits 2 on a stray argument" do
    _stdout, _stderr, status = run_release("2.7.0")

    expect(status.exitstatus).to eq(2)
  end

  it "exits 2 when --gem-only and --npm-only are combined", :aggregate_failures do
    _stdout, stderr, status = run_release("--gem-only", "--npm-only")

    expect(status.exitstatus).to eq(2)
    expect(stderr).to include("cannot be combined")
  end

  it "exits 2 when --no-wait is combined with --npm-local", :aggregate_failures do
    _stdout, stderr, status = run_release("--no-wait", "--npm-local")

    expect(status.exitstatus).to eq(2)
    expect(stderr).to include("--no-wait")
  end

  it "exits 2 when --gem-only is combined with --npm-local" do
    _stdout, _stderr, status = run_release("--gem-only", "--npm-local")

    expect(status.exitstatus).to eq(2)
  end
end
