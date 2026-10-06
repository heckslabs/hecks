require "spec_helper"
require "json"
require "open3"
require "tmpdir"
require_relative "support/rust_conformance_helpers"

# `hecks check_conformance` (Hecks::RustBuild's rust_conformance) must compare `dry_runs`, or a
# dry-run split found by a QualityControl sweep cannot be reproduced. The fixture binary answers
# one phantom dry run per step, so a dry-run script disagrees on `dry_runs` alone.
RSpec.describe "rust conformance dry_runs", :io do
  # Helper methods, not constants: a constant in a describe block lands at top level
  # and can collide with other specs (spec/load_hygiene_spec.rb enforces this).
  def fixture_domain = File.join(InMemoryDomain::ROOT, "spec/fixtures/qa_sweep_all_dry_run_fixture")
  def fixture_crate  = File.join(InMemoryDomain::ROOT, "spec/fixtures/qa_sweep_all_found_fixture_rust")

  # The child's whole program: the library entry point that `hecks check_conformance` runs.
  def conformance_child
    '$LOAD_PATH.unshift("lib"); require "hecks/rust_build"; exit Hecks::RustBuild.run("rust_conformance", ARGV)'
  end

  let(:binary) do
    Object.new.extend(RustConformanceHelpers).build_rust_for("qa_sweep_all_dry_run_fixture", fixture_crate) or
      skip "the qa_sweep_all_found_fixture_rust crate declares no qa_sweep_all_dry_run_fixture feature"
  end

  def run_script(steps, *other)
    Dir.mktmpdir("rust_conformance_spec") do |dir|
      script = File.join(dir, "script.json")
      File.write(script, JSON.generate(name: "spec", steps: steps))
      Open3.capture2e("bundle", "exec", "ruby", "-e", conformance_child, "--", fixture_domain, script, *other,
                      chdir: InMemoryDomain::ROOT)
    end
  end

  it "fails on a dry-run split, naming dry_runs and nothing else", :aggregate_failures do
    output, status = run_script([{ dry_run: "QaSweepAllDryRunFixture::Gate.Open", args: { reference: { value: "north" } } }],
                                binary)

    expect(status.exitstatus).to eq(1), output
    expect(output).to include("1 mismatch(es)", "dry_runs:", "QaSweepAllDryRunFixture::Gate.Open",
                              "__qa_sweep_all_spec_phantom_dry_run__")
  end

  it "still matches a script with no dry run at all", :aggregate_failures do
    output, status = run_script([], binary)

    expect(status.exitstatus).to eq(0), output
    expect(output).to include("matches.")
  end

  it "leaves dry_runs out of Ruby's printed result when the script has none", :aggregate_failures do
    output, status = run_script([])

    expect(status.exitstatus).to eq(0), output
    expect(JSON.parse(output[output.index("{")..]).keys).to eq(%w[instances events refusals])
  end
end
