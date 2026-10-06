require "spec_helper"
require "tmpdir"
require "hecks/fuzzing/domain_generator"
require_relative "support/qa_mine_combinations_helpers"

# `hecks quality_control mine_combinations` as a real subprocess with `--agent` set to a fake agent;
# the plumbing is under test, not the agent. Check and repair rounds are in sibling specs.
RSpec.describe "hecks quality_control mine_combinations" do
  include QaMineCombinationsHelpers

  it "prints the agent's brief — unmet pairs, corpus, bug history — and stops, with --brief", :aggregate_failures do
    out, status = run_miner("--brief", "--candidates", "4", mode: "silent")

    expect(status.exitstatus).to eq(0), out
    expect(out).to include("write 4 NEW candidate Hecks bluebooks", "- qa/stress_domains/case_escalation",
                           "Form pairs NO corpus aggregate meets")
    expect(out).not_to match(/\{\{\w+\}\}/)
  end

  it "exits 1 when the agent writes nothing", :aggregate_failures do
    out, status = run_miner("--candidates", "1", mode: "silent")

    expect(status.exitstatus).to eq(1), out
    expect(out).to include("the agent wrote no candidates")
  end

  it "refuses --confine for an agent that is not the default claude command", :aggregate_failures do
    out, status = run_miner("--confine", "--candidates", "1")

    expect(status.exitstatus).to eq(1), out
    expect(out).to include("permission confinement applies only to the default claude command")
  end

  it "is opt-in: neither the tick nor the dials ever run it", :aggregate_failures do
    tick  = File.read(File.join(InMemoryDomain::ROOT, "lib/hecks/quality_control/cli/qa_tick.rb"))
    dials = File.read(File.join(InMemoryDomain::ROOT, "lib/hecks/quality_control/quality_control.bluebook"))

    expect(tick).not_to match(/^[^#]*qa_mine_combinations/)
    expect(dials).not_to include("qa_mine_combinations")
  end

  def adopted_bluebook
    Dir.mktmpdir do |dir|
      source = File.read(File.join(QaMineCombinationsHelpers::FIXTURES, "mined_desk.bluebook"))
      domain = Hecks::Fuzzing::DomainGenerator.write({ "source" => source, "aggregates" => [], "policies" => [] }, dir)
      File.read(File.join(domain, "bluebook", "qa_generated.bluebook"))
    end
  end

  it "adopts the agent's bluebook under the QaGenerated name, leaving nothing to domain-shrink", :aggregate_failures do
    written = adopted_bluebook

    expect(written).to include('Hecks.bluebook "QaGenerated" do')
    expect(written).not_to include('"MinedDesk"')
    expect(Hecks::Fuzzing::DomainGenerator.removals({ "aggregates" => [], "policies" => [] })).to be_empty
  end
end
