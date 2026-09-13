require "spec_helper"
require "json"
require "open3"
require "tmpdir"
require_relative "support/rust_conformance_helpers"

# `bin/rust_conformance` COMPARES DRY RUNS. Before this, a `{"dry_run":
# verb}` step's answer was invisible to the script, so a dry-run split
# `bin/qa_sweep` had found (`Hecks::Fuzzing::Differential` compares
# `dry_runs`) could not be given a failing demonstration for
# `bin/qa_log_bug`.
#
# The fixture is the one `spec/qa_sweep_all_report_and_parity_spec.rb`
# already proves the sweep's own dry-run surface with:
# `qa_sweep_all_dry_run_fixture`'s hand-written binary answers empty
# instances/events/refusals plus one PHANTOM dry run per `"dry_run":` step,
# so a dry-run script disagrees on `dry_runs` and on nothing else.
RSpec.describe "bin/rust_conformance", :io do
  FIXTURE_DOMAIN   = File.join(InMemoryDomain::ROOT, "spec/fixtures/qa_sweep_all_dry_run_fixture").freeze
  FIXTURE_CRATE    = File.join(InMemoryDomain::ROOT, "spec/fixtures/qa_sweep_all_found_fixture_rust").freeze
  CONFORMANCE_BIN  = File.join(InMemoryDomain::ROOT, "bin/rust_conformance").freeze

  let(:binary) do
    Object.new.extend(RustConformanceHelpers).build_rust_for("qa_sweep_all_dry_run_fixture", FIXTURE_CRATE) or
      skip "could not build the qa_sweep_all_dry_run_fixture crate — is cargo installed?"
  end

  def run_script(steps, *other)
    Dir.mktmpdir("rust_conformance_spec") do |dir|
      script = File.join(dir, "script.json")
      File.write(script, JSON.generate(name: "spec", steps: steps))
      Open3.capture2e("bundle", "exec", "ruby", CONFORMANCE_BIN, FIXTURE_DOMAIN, script, *other,
                      chdir: InMemoryDomain::ROOT)
    end
  end

  it "fails on a dry-run split, naming dry_runs and nothing else" do
    output, status = run_script([{ dry_run: "QaSweepAllDryRunFixture::Gate.Open", args: { reference: { value: "north" } } }],
                                binary)

    expect(status.exitstatus).to eq(1), output
    expect(output).to include("1 mismatch(es)", "dry_runs:", "QaSweepAllDryRunFixture::Gate.Open",
                              "__qa_sweep_all_spec_phantom_dry_run__")
  end

  it "still matches a script with no dry run at all" do
    output, status = run_script([], binary)

    expect(status.exitstatus).to eq(0), output
    expect(output).to include("matches.")
  end

  it "leaves dry_runs out of Ruby's printed result when the script has none" do
    output, status = run_script([])

    expect(status.exitstatus).to eq(0), output
    expect(JSON.parse(output[output.index("{")..]).keys).to eq(%w[instances events refusals])
  end
end
