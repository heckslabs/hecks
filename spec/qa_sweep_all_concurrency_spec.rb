require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `bin/qa_sweep --all` concurrency: the pool bound under real load.
# Own throwaway database: `hecks_qa_sweep_all_concurrency_spec`.
RSpec.describe "bin/qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_concurrency_spec"

  # Pins the real `QualityControlDials::SWEEP_MAX_PARALLEL`. Children are grandchildren, so
  # liveness is sampled with `ps`; two alive at once proves the sampling saw real concurrency.
  # Reaped via `reap_while_polling`: a `Process.kill(0, pid)` loop hangs on zombies.
  it "keeps at most SWEEP_MAX_PARALLEL real bin/qa_sweep children alive at once" do
    Hecks.boot(@fixture_dir)
    max_parallel = QualityControlDials::SWEEP_MAX_PARALLEL
    targets = (1..(max_parallel + 2)).to_h { |n| ["pool_#{n}", @target_domain_relpath] }
    targets.each { |reference, path| QualityControl::Target.identify!(reference: { value: reference }, path: { value: path }) }

    log = Tempfile.new("pool")
    pid = Process.spawn(
      { "QA_SWEEP_DOMAIN_DIR" => @fixture_dir },
      "bundle", "exec", "ruby", File.join(InMemoryDomain::ROOT, "bin/qa_sweep"), "--all", "--seeds", "2",
      out: log, err: log, chdir: InMemoryDomain::ROOT
    )

    status, alive_counts = reap_while_polling(pid) { `ps -eo args`.lines.count { |line| line.include?("bin/qa_sweep pool_") } }
    log.rewind
    output = log.read
    log.close

    expect(status.exitstatus).to eq(0), output
    expect(output).to include("at most #{max_parallel} at once", "clean (#{targets.size})")
    expect(alive_counts.max).to be >= 2
    expect(alive_counts.max).to be <= max_parallel
  end
end
