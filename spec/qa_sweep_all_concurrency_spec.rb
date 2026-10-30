require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `qa_sweep --all` concurrency: the pool bound under real load.
# Own throwaway database: `hecks_qa_sweep_all_concurrency_spec`.
RSpec.describe "qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_concurrency_spec"

  def max_parallel = QualityControlDials::SWEEP_MAX_PARALLEL

  # Boots the fixture domain and identifies `max_parallel + 2` targets; answers their references.
  def identify_pool_targets
    Hecks.boot(@fixture_dir)
    targets = (1..(max_parallel + 2)).to_h { |n| ["pool_#{n}", @target_domain_relpath] }
    targets.each { |reference, path| QualityControl::Target.identify!(reference: { value: reference }, path: { value: path }) }
    targets
  end

  def spawn_pool_sweep(log)
    Process.spawn(
      { "QA_SWEEP_DOMAIN_DIR" => @fixture_dir },
      *Hecks::QualityControlCli::Child.argv(InMemoryDomain::ROOT, "qa_sweep", "--all", "--seeds", "2"),
      out: log, err: log, chdir: InMemoryDomain::ROOT
    )
  end

  # Runs `qa_sweep --all` to the end, sampling how many children are alive; answers its exit status,
  # the samples and what it printed.
  def pooled_sweep
    log = Tempfile.new("pool")
    status, alive_counts = reap_while_polling(spawn_pool_sweep(log)) do
      `ps -eo args`.lines.count { |line| line.include?("QaSweep.call") && line.include?("-- pool_") }
    end
    log.rewind
    output = log.read
    log.close
    [status, alive_counts, output]
  end

  # Pins the real `QualityControlDials::SWEEP_MAX_PARALLEL`. Children are grandchildren, so
  # liveness is sampled with `ps`; two alive at once proves the sampling saw real concurrency.
  # Reaped via `reap_while_polling`: a `Process.kill(0, pid)` loop hangs on zombies.
  it "keeps at most SWEEP_MAX_PARALLEL real qa_sweep children alive at once", :aggregate_failures do
    targets = identify_pool_targets
    status, alive_counts, output = pooled_sweep

    expect(status.exitstatus).to eq(0), output
    expect(output).to include("at most #{max_parallel} at once", "clean (#{targets.size})")
    expect(alive_counts.max).to be_between(2, max_parallel)
  end
end
