require "spec_helper"
require "yaml"
require "hecks/fuzzing/target_capabilities"

# A sweep mode counts as enabled only if the sweep command has code for it. The runner is the
# oracle: comments are stripped before grepping, since prose naming a mode is not an implementation.
RSpec.describe "sweep modes that actually run" do
  let(:root) { InMemoryDomain::ROOT }
  let(:runnable) { Hecks::Fuzzing::TargetCapabilities::RUNNABLE_MODES }
  let(:declared) { Hecks::Fuzzing::TargetCapabilities::MODE_REQUIREMENTS.keys }
  let(:runner_files) { Dir[File.join(root, "lib/hecks/quality_control/cli/qa_sweep{.rb,/*.rb}")].sort }
  let(:runner_code) { runner_files.flat_map { |file| File.readlines(file) }.grep_v(/\A\s*#/).join }

  it "names only modes the capability table declares" do
    expect(runnable - declared).to be_empty
  end

  it "agrees with the sweep command's own code about which modes it implements" do
    implemented = declared.select { |mode| runner_code.match?(/\b#{Regexp.escape(mode.to_s)}\b/) }

    expect(implemented.sort).to eq(runnable.sort),
                                "the sweep command implements #{implemented.sort.inspect} but RUNNABLE_MODES says " \
                                "#{runnable.sort.inspect} — add the missing name, or delete the one with no code"
  end

  it "enables no mode in qa/settings.yml that nothing runs" do
    enabled = YAML.load_file(File.join(root, "qa/settings.yml")).fetch("modes").select { |_, on| on }.keys.map(&:to_sym)

    expect(enabled - runnable).to be_empty,
                                  "qa/settings.yml enables #{(enabled - runnable).inspect}, which the sweep command " \
                                  "cannot run — a sweep would advertise it and check nothing"
  end
end
