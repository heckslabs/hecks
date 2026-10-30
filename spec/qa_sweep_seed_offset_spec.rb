require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/qa_sweep_all_fixture"

# `qa_sweep`'s seed-range advance: once a target's streak has widened its depth to
# `SweepDepth`'s ceiling tier, the tier stops changing, so without an offset every later tick
# would sweep the identical `1..seeds` integers — and, since `SequenceGenerator` is a pure
# function of the seed, the identical generated sequences — forever.
RSpec.describe "qa_sweep seed range", :io do
  include_context "with a qa_sweep_all fixture", "hecks_qa_sweep_seed_offset_spec"

  # Moves `clean_streak` the way `Target::Release` really does (this is exactly what
  # `qa_sweep` itself calls at the end of a clean sweep), without sweeping the target clean
  # over and over just to climb there.
  def fast_forward_streak!(reference, next_streak)
    Hecks.boot(@fixture_dir)
    target = QualityControl::Target.find(reference)
    target.claim!(held_by: { value: "spec" }, now: { value: Time.now.to_i })
    target.release!(now: { value: Time.now.to_i }, yield_score: { value: 0 },
                    next_streak: { value: next_streak }, capabilities: { value: "sqlite" })
  end

  # Sweeps the fixture target (with any extra flags), expects a clean exit, and answers stdout.
  def sweep_ok(*flags)
    stdout, _stderr, status = run_qa_sweep("seed_offset_target", *flags)
    expect(status.exitstatus).to eq(0), stdout
    stdout
  end

  before { identify_targets!("seed_offset_target" => @target_domain_relpath) }

  it "sweeps the familiar 1..seeds for a fresh target, whose streak is 0" do
    expect(sweep_ok).to include("resolved depth: seeds=10 steps=25 (clean_streak=0)", "seed range: 1..10")
  end

  it "advances the range forward one full stride per clean release, once widened" do
    fast_forward_streak!("seed_offset_target", 20)

    expect(sweep_ok).to include("resolved depth: seeds=50 steps=100 (clean_streak=20)", "seed range: 1001..1050")
  end

  # Keeps the ceiling tier's seed count, but the two ranges are back to back, never overlapping.
  it "advances the range by a further full stride for each further clean release" do
    fast_forward_streak!("seed_offset_target", 21)

    expect(sweep_ok).to include("resolved depth: seeds=50 steps=100 (clean_streak=21)", "seed range: 1051..1100")
  end

  it "keeps an explicit --seeds at the predictable 1..N, whatever the streak has climbed to" do
    fast_forward_streak!("seed_offset_target", 20)

    expect(sweep_ok("--seeds", "3")).to include("resolved depth: seeds=3", "seed range: 1..3")
  end

  it "resets the range back to 1..seeds once a streak reset lands the target back at 0" do
    fast_forward_streak!("seed_offset_target", 20)
    fast_forward_streak!("seed_offset_target", 0)

    expect(sweep_ok).to include("resolved depth: seeds=10 steps=25 (clean_streak=0)", "seed range: 1..10")
  end
end
