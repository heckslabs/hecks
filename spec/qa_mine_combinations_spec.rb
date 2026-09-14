require "spec_helper"
require "tmpdir"
require "hecks/fuzzing/domain_generator"
require_relative "support/qa_mine_combinations_helpers"

# `bin/qa_mine_combinations` — an agent writes candidate bluebooks, the
# script checks them through `bin/qa_generated_domains --source`. Proven as
# a real subprocess with `--agent` pointed at a fake (spec/fixtures/
# qa_mine_combinations/fake_agent): the agent's judgment is not what is
# under test, the plumbing around it is. This file holds the fast half;
# the candidate check and the repair rounds live in
# qa_mine_combinations_check_spec.rb and qa_mine_combinations_repair_spec.rb
# (spec/support/qa_mine_combinations_helpers.rb says why three files).
RSpec.describe "bin/qa_mine_combinations" do
  include QaMineCombinationsHelpers

  it "prints the agent's brief — unmet pairs, corpus, bug history — and stops, with --brief" do
    out, status = run_miner("--brief", "--candidates", "4", mode: "silent")

    expect(status.exitstatus).to eq(0), out
    expect(out).to include("write 4 NEW candidate Hecks bluebooks")
    expect(out).to include("- qa/stress_domains/case_escalation")
    expect(out).to include("Form pairs NO corpus aggregate meets")
    expect(out).not_to match(/\{\{\w+\}\}/)
  end

  it "exits 1 when the agent writes nothing" do
    out, status = run_miner("--candidates", "1", mode: "silent")

    expect(status.exitstatus).to eq(1), out
    expect(out).to include("the agent wrote no candidates")
  end

  it "is opt-in: neither the tick nor the dials ever run it" do
    tick  = File.read(File.join(InMemoryDomain::ROOT, "bin/qa_tick"))
    dials = File.read(File.join(InMemoryDomain::ROOT, "qa/bluebook/quality_control.bluebook"))

    expect(tick).not_to match(/^[^#]*qa_mine_combinations/)
    expect(dials).not_to include("qa_mine_combinations")
  end

  it "adopts the agent's bluebook under the QaGenerated name, leaving nothing to domain-shrink" do
    Dir.mktmpdir do |dir|
      source = File.read(File.join(QaMineCombinationsHelpers::FIXTURES, "mined_desk.bluebook"))
      domain = Hecks::Fuzzing::DomainGenerator.write({ "source" => source, "aggregates" => [], "policies" => [] }, dir)
      written = File.read(File.join(domain, "bluebook", "qa_generated.bluebook"))

      expect(written).to include('Hecks.bluebook "QaGenerated" do')
      expect(written).not_to include('"MinedDesk"')
      expect(Hecks::Fuzzing::DomainGenerator.removals({ "aggregates" => [], "policies" => [] })).to be_empty
    end
  end
end
