require "spec_helper"

# A beat of the clock, or a promotion to stable, asks whether stable holds changes no release
# covers and whether the oldest has soaked. A soaked patch or minor cuts the next release after
# `soak_days`, a major after `major_soak_days`, and nothing is cut while a bump waits for its tag.
RSpec.describe "the next release is cut after a soak" do
  let(:domain) { File.expand_path("../lib/hecks/hecks", __dir__) }
  let(:bumped) { [] }
  let(:quiet) { { unreleased: 3, oldest_days: 8, non_additive: false, added_surface: false, bump_pending: false } }

  # Answers the facts it was given, with the soak settings of the stable Lane row.
  class Survey
    def initialize(facts) = @facts = facts.transform_values { |fact| { value: fact } }

    def survey(**) = @facts.merge(soak_days: { value: 7 }, major_soak_days: { value: 21 })
  end

  # Records the level each bump was asked for.
  class Cutting
    def initialize(log) = @log = log

    def bump(**held)
      level = held[:level]
      @log << (level.is_a?(Hash) ? level[:value] : level)
      { version: { value: "1.0.0" } }
    end
  end

  def adapters(facts)
    ports = { "Surveying" => Survey.new(facts), "Cutting" => Cutting.new(bumped) }
    ->(port, _asked) { ports[port.to_s] }
  end

  def beat_with(facts)
    registry = boot_hecks_in_memory(domain).registry
    Hecks::Runtime::AdapterLookup.standing_in(adapters(facts)) do
      Hecks::Runtime::Dispatcher.new(registry).dispatch_flat("Hecks::Heartbeat.Beat", beat: { value: "beat-1" })
    end
    registry.event_log.map(&:name)
  end

  it "cuts a patch once the oldest unreleased change has stood the soak", :aggregate_failures do
    expect(beat_with(quiet)).to include("ReleaseCutDue", "ReleaseBumped")
    expect(bumped).to eq(["patch"])
  end

  it "cuts a minor when a change added a command, a flag or a concept" do
    beat_with(quiet.merge(added_surface: true))

    expect(bumped).to eq(["minor"])
  end

  it "waits while the oldest change has not stood the soak" do
    expect(beat_with(quiet.merge(oldest_days: 3))).not_to include("ReleaseCutDue")
  end

  it "makes a major wait its own longer soak", :aggregate_failures do
    expect(beat_with(quiet.merge(non_additive: true, oldest_days: 10))).not_to include("ReleaseCutDue")
    expect(beat_with(quiet.merge(non_additive: true, oldest_days: 22))).to include("ReleaseCutDue")
    expect(bumped).to eq(["major"])
  end

  it "cuts nothing while the last bump still waits for its tag" do
    expect(beat_with(quiet.merge(bump_pending: true))).not_to include("ReleaseCutDue")
  end

  it "cuts nothing when stable holds no change a release lacks" do
    expect(beat_with(quiet.merge(unreleased: 0))).not_to include("ReleaseCutDue")
  end
end
