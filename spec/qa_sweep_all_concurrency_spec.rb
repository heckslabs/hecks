require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `bin/qa_sweep --all` — CONCURRENCY MECHANICS. One of four sibling files
# split out of the original `qa_sweep_all_spec.rb` (Phase 2 of the CI
# speed effort — see `spec/qa_sweep_all_lifecycle_spec.rb`'s own header
# and `spec/support/qa_sweep_all_fixture.rb` for the full context). This
# file proves the pool itself: two real children genuinely alive at
# once, the pool bound holding under real load, and a pool of
# near-instantly-exiting children draining without stalling — the
# heaviest group of the four by wall-clock (this file's own throwaway
# database is `hecks_qa_sweep_all_concurrency_spec`, unique so it never
# races a sibling file's own scratch resources).
RSpec.describe "bin/qa_sweep --all", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_all_concurrency_spec"

  # THE CENTRAL CLAIM `--all` EXISTS FOR, PROVEN WITHOUT TRUSTING THE
  # CLOCK. PID LIVENESS DOES NOT HAVE THE "shared machine under load"
  # flakiness a wall-clock comparison would: two real `bin/qa_sweep
  # <target>` children (the exact same spawn shape `spawn_sweep_child`
  # uses per target inside `--all` itself) are spawned back to back
  # (`Process.spawn` returns immediately either way), then checked for
  # life together immediately after. A SERIALIZED implementation could
  # NEVER have a second `bin/qa_sweep` process alive before the first one
  # exits, no matter how fast or slow the machine is at that moment.
  it "runs two real bin/qa_sweep children as genuinely concurrent OS processes — both alive at once" do
    identify_targets!(
      "clone_one" => @target_domain_relpath,
      "clone_two" => @target_domain_relpath
    )

    children = %w[clone_one clone_two].map do |target_reference|
      log = Tempfile.new(target_reference)
      pid = Process.spawn(
        { "QA_SWEEP_DOMAIN_DIR" => @fixture_dir },
        "bundle", "exec", "ruby", File.join(InMemoryDomain::ROOT, "bin/qa_sweep"), target_reference, "--seeds", "3",
        out: log, err: log, chdir: InMemoryDomain::ROOT
      )
      { pid: pid, log: log }
    end

    both_alive_at_once = children.all? { |c| process_alive?(c[:pid]) }

    exit_statuses = children.map do |c|
      _pid, status = Process.waitpid2(c[:pid])
      c[:log].close
      status.exitstatus
    end

    expect(both_alive_at_once).to be true
    expect(exit_statuses).to all(eq(0))
  end

  # THE POOL BOUND — `QualityControlDials::SWEEP_MAX_PARALLEL` (read here
  # from the same symlinked bluebook the fixture ledger boots, so this
  # spec pins the REAL dial, not a copy of it). Six targets, a pool of
  # four: the children are grandchildren of this process (spawned by the
  # real `bin/qa_sweep --all` subprocess), so liveness is read the one
  # way a grandparent can — `ps`, sampled while `--all` runs. The upper
  # bound is the claim; the lower bound (at least two at once) is what
  # proves the sampling saw real concurrency rather than an idle moment.
  # REAPED VIA `reap_while_polling` (see the shared fixture's own header
  # on why a `process_alive?` loop cannot safely watch for exit here —
  # confirmed live: a real run hung over an hour on a zombie before this
  # was fixed).
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

  # THE FAILURE MODE THAT PROMPTED THE POOL BOUND EXAMPLE'S OWN COMMENT,
  # EXERCISED DIRECTLY — not just the happy path where children happen to
  # take a couple of seconds each. Every target here finishes about as
  # fast as a real OS process CAN, so several children exit within the
  # SAME `Process.wait2(-1)` polling window inside `run_pool`
  # (bin/qa_sweep) — the exact "a spawned child exits very early/fast"
  # shape a bounded pool's bookkeeping has to survive.
  it "drains a pool of near-instantly-exiting children without stalling" do
    Hecks.boot(@fixture_dir)
    max_parallel = QualityControlDials::SWEEP_MAX_PARALLEL
    targets = (1..(max_parallel * 3)).to_h { |n| ["fast_#{n}", @target_domain_relpath] }
    targets.each { |reference, path| QualityControl::Target.identify!(reference: { value: reference }, path: { value: path }) }

    stdout, stderr, status = run_qa_sweep("--all", "--seeds", "1", "--steps", "1")

    expect(status.exitstatus).to eq(0), "expected a clean --all, got:\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
    expect(stdout).to include("clean (#{targets.size})")
  end
end
