require "open3"

# Shared by the three `bin/qa_mine_combinations` spec files.
# Split in three so parallel_rspec can spread their subprocess examples across workers.
module QaMineCombinationsHelpers
  FIXTURES = File.join(InMemoryDomain::ROOT, "spec/fixtures/qa_mine_combinations").freeze
  # One domain, not the full census, which costs ~8s per run.
  CORPUS = File.join(InMemoryDomain::ROOT, "qa/stress_domains/case_escalation").freeze

  def run_miner(*, mode: "valid")
    env = { "FAKE_AGENT_MODE" => mode, "QA_MINER_AGENT" => "ruby #{File.join(FIXTURES, 'fake_agent')}" }
    Open3.capture2e(env, "bundle", "exec", "ruby", File.join(InMemoryDomain::ROOT, "bin/qa_mine_combinations"),
                    "--against", CORPUS, *, chdir: InMemoryDomain::ROOT)
  end
end
