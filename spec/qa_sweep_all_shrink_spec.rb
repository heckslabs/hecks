require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `qa_sweep --all`: shrinking.
# Own throwaway database: `hecks_qa_sweep_all_shrink_spec`.
RSpec.describe "qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_shrink_spec"

  FOUND_FIXTURE = "spec/fixtures/qa_sweep_all_found_fixture".freeze

  # Sweeps the found-one fixture registered under `reference`; answers stdout and the exit status.
  def sweep_found(reference)
    identify_targets!(reference => FOUND_FIXTURE)
    stdout, _stderr, status = run_qa_sweep("--all", "--seeds", "1", "--no-parity")
    [stdout, status]
  end

  def shrunk_file_in(stdout) = stdout[%r{^file:        (tmp/qa-shrunk/\S+-differential\.json)$}, 1]

  def shrunk_steps(stdout)
    JSON.parse(File.read(File.join(InMemoryDomain::ROOT, shrunk_file_in(stdout)))).fetch("steps")
  end

  def shrunk_to(stdout) = stdout[/^shrunk:      \[differential\] 25 -> (\d+) step\(s\)/, 1].to_i

  # `found_one`'s fixture binary answers the same phantom result for any script, so the finding
  # survives on a few of the 25 steps; the named file must hold exactly the steps printed.
  it "shrinks a differential finding before reporting it", :aggregate_failures do
    stdout, status = sweep_found("found_one")

    expect(status.exitstatus).to eq(2)
    expect(shrunk_to(stdout)).to be_between(1, 3)
    expect(stdout).to include("replay:      hecks check_conformance domain=", "-- shrunk steps [differential] --")
  end

  it "writes a replayable file holding exactly the steps it printed" do
    stdout, = sweep_found("found_one")

    expect(shrunk_steps(stdout).size).to eq(shrunk_to(stdout))
  end

  # `qa_discover_external_domains` suggests `repo/entity`-shaped references for an external
  # domain (e.g. `shop/shop`). `write_shrunk!` folds that `/` into the shrunk-repro
  # filename, and `FileUtils.mkdir_p` only creates `tmp/qa-shrunk` itself, not the extra directory
  # segment an embedded `/` would otherwise imply, so the filename component is sanitized before
  # `File.write` runs. The reference itself keeps its `/` in the ledger; only the filename derived
  # from it changes.
  it "shrinks a finding for a target whose reference contains a `/`, without an ENOENT on write", :aggregate_failures do
    stdout, status = sweep_found("vendor/found_one")
    shrunk_file = shrunk_file_in(stdout)

    expect(status.exitstatus).to eq(2)
    expect(shrunk_file).not_to be_nil, stdout
    expect(shrunk_file).to start_with("tmp/qa-shrunk/SW-vendor-found_one-")
  end

  it "writes the shrunk file for such a target with steps in it" do
    stdout, = sweep_found("vendor/found_one")

    expect(shrunk_steps(stdout)).not_to be_empty
  end
end
