require "spec_helper"
require "yaml"
require "hecks/fuzzing/target_capabilities"

# ENABLED MUST MEAN BUILT — the drift this spec exists for was live:
# `qa/settings.yml` had `wasm_front: true` and `adapter_parity_postgres:
# true` while `bin/qa_sweep` held no code for either. Neither is a seat,
# neither folds into the per-seed loop, neither has a `MODE_EXPECTATIONS`
# entry — yet both resolved, printed on the `resolved modes:` line, and
# logged no Check at all, so the sweep's own report claimed a comparison
# nobody had written.
#
# THE RUNNER ITSELF IS THE ORACLE, not a second hand-kept list: for every
# mode the capability table names, this greps `bin/qa_sweep`'s own code
# (comments stripped — prose naming a mode is not an implementation of
# it) and requires that mentioning it and listing it in `RUNNABLE_MODES`
# agree. So adding the code and forgetting the list fails here, and so
# does listing a mode whose code was never written or has been removed.
RSpec.describe "sweep modes that actually run" do
  let(:root) { InMemoryDomain::ROOT }
  let(:runnable) { Hecks::Fuzzing::TargetCapabilities::RUNNABLE_MODES }
  let(:declared) { Hecks::Fuzzing::TargetCapabilities::MODE_REQUIREMENTS.keys }
  let(:runner_code) do
    File.readlines(File.join(root, "bin/qa_sweep")).grep_v(/\A\s*#/).join
  end

  it "names only modes the capability table declares" do
    expect(runnable - declared).to be_empty
  end

  it "agrees with bin/qa_sweep's own code about which modes it implements" do
    implemented = declared.select { |mode| runner_code.match?(/\b#{Regexp.escape(mode.to_s)}\b/) }

    expect(implemented.sort).to eq(runnable.sort),
                                "bin/qa_sweep implements #{implemented.sort.inspect} but RUNNABLE_MODES says " \
                                "#{runnable.sort.inspect} — add the missing name, or delete the one with no code"
  end

  it "enables no mode in qa/settings.yml that nothing runs" do
    enabled = YAML.load_file(File.join(root, "qa/settings.yml")).fetch("modes").select { |_, on| on }.keys.map(&:to_sym)

    expect(enabled - runnable).to be_empty,
                                  "qa/settings.yml enables #{(enabled - runnable).inspect}, which bin/qa_sweep " \
                                  "cannot run — a sweep would advertise it and check nothing"
  end
end
