require "spec_helper"
require "open3"
require "tmpdir"
require "hecks/fuzzing/domain_generator"

# `bin/qa_mine_combinations` — an agent writes candidate bluebooks, the
# script checks them through `bin/qa_generated_domains --source`. Proven as
# a real subprocess with `--agent` pointed at a fake (spec/fixtures/
# qa_mine_combinations/fake_agent): the agent's judgment is not what is
# under test, the plumbing around it is.
RSpec.describe "bin/qa_mine_combinations" do
  MINER_FIXTURES = File.join(InMemoryDomain::ROOT, "spec/fixtures/qa_mine_combinations").freeze
  # ONE CORPUS DOMAIN, NOT ALL OF THEM — the full census (every stress
  # domain and example) costs ~8s per run and every example here runs the
  # script; the brief's shape is the same over one domain as over nineteen.
  MINER_CORPUS = File.join(InMemoryDomain::ROOT, "qa/stress_domains/case_escalation").freeze

  def run_miner(*args, mode: "valid")
    env = { "FAKE_AGENT_MODE" => mode, "QA_MINER_AGENT" => "ruby #{File.join(MINER_FIXTURES, 'fake_agent')}" }
    Open3.capture2e(env, "bundle", "exec", "ruby", File.join(InMemoryDomain::ROOT, "bin/qa_mine_combinations"),
                    "--against", MINER_CORPUS, *args, chdir: InMemoryDomain::ROOT)
  end

  it "prints the agent's brief — unmet pairs, corpus, bug history — and stops, with --brief" do
    out, status = run_miner("--brief", "--candidates", "4", mode: "silent")

    expect(status.exitstatus).to eq(0), out
    expect(out).to include("write 4 NEW candidate Hecks bluebooks")
    expect(out).to include("- qa/stress_domains/case_escalation")
    expect(out).to include("Form pairs NO corpus aggregate meets")
    expect(out).not_to match(/\{\{\w+\}\}/)
  end

  it "checks what the agent wrote through qa_generated_domains --source, and exits with its verdict" do
    out, status = run_miner("--candidates", "1", "--seeds", "1", "--steps", "4")

    expect(status.exitstatus).to eq(0), out
    expect(out).to include("mined_desk: boots")
    expect(out).to include("[source:mined_desk]: clean")
    expect(out).to include("generated domains: 1 clean, 0 found something")
  end

  it "sends a candidate that does not boot back to the agent, and checks the repaired file" do
    out, status = run_miner("--candidates", "1", "--seeds", "1", "--steps", "4", mode: "repair")

    expect(status.exitstatus).to eq(0), out
    expect(out).to include("repair round 1: 1 candidate(s) did not boot")
    expect(out).to include("mined_desk: boots (repaired)")
  end

  it "reports a candidate still broken after the repair rounds as INVALID and exits 1 with nothing to check" do
    out, status = run_miner("--candidates", "1", "--repair-rounds", "0", mode: "repair")

    expect(status.exitstatus).to eq(1), out
    expect(out).to include("mined_desk: INVALID")
    expect(out).to include("no candidate booted")
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
      source = File.read(File.join(MINER_FIXTURES, "mined_desk.bluebook"))
      domain = Hecks::Fuzzing::DomainGenerator.write({ "source" => source, "aggregates" => [], "policies" => [] }, dir)
      written = File.read(File.join(domain, "bluebook", "qa_generated.bluebook"))

      expect(written).to include('Hecks.bluebook "QaGenerated" do')
      expect(written).not_to include('"MinedDesk"')
      expect(Hecks::Fuzzing::DomainGenerator.removals({ "aggregates" => [], "policies" => [] })).to be_empty
    end
  end
end
