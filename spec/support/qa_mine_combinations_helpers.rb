require_relative "qa_lib_cli"

# Shared by the three `hecks quality_control mine_combinations` spec files.
# Split in three so parallel_rspec can spread their subprocess examples across workers.
module QaMineCombinationsHelpers
  FIXTURES = File.join(InMemoryDomain::ROOT, "spec/fixtures/qa_mine_combinations").freeze
  # One domain, not the full census, which costs ~8s per run.
  CORPUS = File.join(InMemoryDomain::ROOT, "qa/stress_domains/case_escalation").freeze

  def run_miner(*, mode: "valid")
    env = { "FAKE_AGENT_MODE" => mode, "QA_MINER_AGENT" => "ruby #{File.join(FIXTURES, "fake_agent")}" }
    QaLibCli.capture2e("qa_mine_combinations", "--against", CORPUS, *, env: env)
  end
end
