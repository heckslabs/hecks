require "open3"

# Shared by the three `bin/qa_mine_combinations` spec files
# (qa_mine_combinations_spec.rb, _check_spec.rb, _repair_spec.rb).
#
# Three files, not one, for the shards. Every subprocess example boots
# Ruby and bundler several times over (the miner, its boot check, then
# `bin/qa_generated_domains` and its child), ~5-25s each on a CI runner.
# In one file they were ~70s that parallel_rspec cannot split across
# workers, so that one file was the slowest worker and set the whole
# `rspec_shard` leg's wall-clock (PR #685's run: 75.7s on one worker, the
# other three ~45s). Separate files let runtime grouping spread them.
module QaMineCombinationsHelpers
  FIXTURES = File.join(InMemoryDomain::ROOT, "spec/fixtures/qa_mine_combinations").freeze
  # One CORPUS domain, not all of them — the full census (every stress
  # domain and example) costs ~8s per run and every example here runs the
  # script; the brief's shape is the same over one domain as over nineteen.
  CORPUS = File.join(InMemoryDomain::ROOT, "qa/stress_domains/case_escalation").freeze

  def run_miner(*, mode: "valid")
    env = { "FAKE_AGENT_MODE" => mode, "QA_MINER_AGENT" => "ruby #{File.join(FIXTURES, 'fake_agent')}" }
    Open3.capture2e(env, "bundle", "exec", "ruby", File.join(InMemoryDomain::ROOT, "bin/qa_mine_combinations"),
                    "--against", CORPUS, *, chdir: InMemoryDomain::ROOT)
  end
end
