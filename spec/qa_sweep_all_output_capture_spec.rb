require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `qa_sweep --all` output capture: the consolidated report never interleaves children's output.
# Own throwaway database: `hecks_qa_sweep_all_output_spec`.
RSpec.describe "qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_output_spec"

  # A finding, an operational error and a clean target at once, each child writing its own file.
  # `found_one` diffs a Ruby domain against `spec/fixtures/qa_sweep_all_found_fixture_rust`, whose
  # binary always answers a fixed mismatch, so the finding never depends on the fuzzer.
  it "captures each child's own output without interleaving, and a real finding outranks a real error" do
    identify_targets!(
      "clean_one"  => @target_domain_relpath,
      "found_one"  => "spec/fixtures/qa_sweep_all_found_fixture",
      "broken_one" => "qa/stress_domains/__qa_sweep_all_spec_does_not_exist__"
    )

    stdout, _stderr, status = run_qa_sweep("--all", "--seeds", "2")

    expect(status.exitstatus).to eq(2)
    expect(stdout).to include("clean (1): clean_one", "OPERATIONAL ERRORS (1)",
                              "-- broken_one (exit 1) --", "FOUND SOMETHING (1)")

    # `found_one`'s report prints last, so everything after its header came from one child's file.
    found_report = stdout[/^#{'#' * 72}\n# found_one\n.*\z/m]
    expect(found_report).not_to be_nil
    expect(found_report).to include("target:      found_one", "sweep:       SW-found_one-",
                                    "-- instances --", "-- events --")
    expect(found_report).not_to include("clean_one", "broken_one")

    # Suspended by the ledger's `SuspendOnSurprise` policy, fired in `Sweep.Check.Surprised`.
    expect(found_report).to include("target found_one SUSPENDED", "--release --notes")
    runtime = Hecks.boot(@fixture_dir)
    found = QualityControl::Target.find("found_one")
    expect(found.status).to eq("suspended")
    expect(found.reason.to_h[:value]).to include("--release")
    rotation = runtime.query("QualityControl::Target.Rotation").map { |row| row[:reference][:value] }
    expect(rotation).to include("clean_one")
    expect(rotation).not_to include("found_one")
  end
end
