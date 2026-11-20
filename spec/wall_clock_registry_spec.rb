# frozen_string_literal: true

require "spec_helper"
require_relative "support/wall_clock_scan"

# A wall-clock bound cannot sink a train on a slow runner: every timing example is tagged
# `:wall_clock`, listed in WallClock::EXAMPLES, and asserts through `expect_wall_clock`, which
# stretches the bound on CI and turns a breach there into a pending finding.
RSpec.describe WallClock do
  def with_env(values)
    saved = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  it "lists every example tagged :wall_clock, and no other" do
    expect(WallClock::Scan.tagged.sort).to eq(WallClock::EXAMPLES.sort)
  end

  it "finds no wall-clock bound outside expect_wall_clock" do
    expect(WallClock::Scan.untagged_bounds).to eq([])
  end

  it "holds a bound as written off CI" do
    with_env("CI" => nil, "HECKS_WALL_CLOCK_MULTIPLIER" => nil) { expect(described_class.bound(2, stretched: true)).to eq(2.0) }
  end

  it "stretches an absolute bound on CI" do
    with_env("CI" => "1", "HECKS_WALL_CLOCK_MULTIPLIER" => nil) { expect(described_class.bound(2, stretched: true)).to eq(8.0) }
  end

  it "never stretches a bound passed stretched: false" do
    with_env("CI" => "1", "HECKS_WALL_CLOCK_MULTIPLIER" => "9") { expect(described_class.bound(3, stretched: false)).to eq(3.0) }
  end

  it "fails a breach on CI when the run is strict" do
    with_env("CI" => "1", "HECKS_WALL_CLOCK_STRICT" => "1") { expect(described_class.forgiving?).to be(false) }
  end

  it "refuses an example that is not tagged :wall_clock" do
    expect { expect_wall_clock(0, under: 1) }.to raise_error(ArgumentError, /needs the :wall_clock tag/)
  end

  context "when a tagged example breaches on CI" do
    let(:findings) { File.join(Dir.mktmpdir("wall-clock"), "findings.jsonl") }
    let(:breached) { RSpec::Core::ExampleGroup.describe("a slow runner") { it("breaches", :wall_clock) { expect_wall_clock(5.0, under: 1) } }.examples.first }

    before { stub_const("WallClock::FINDINGS", findings) }

    after { FileUtils.rm_rf(File.dirname(findings)) }

    # Runs the breaching example off the world, in a CI environment, and answers its result.
    def run_on_ci(example)
      outer = RSpec.current_example
      with_env("CI" => "1", "HECKS_WALL_CLOCK_STRICT" => nil, "HECKS_WALL_CLOCK_MULTIPLIER" => nil) do
        example.run(example.example_group.new, RSpec::Core::NullReporter)
      end
      example.execution_result
    ensure
      RSpec.current_example = outer
    end

    it "is pending with the breach as a live exception, so the CI skip backstop passes it", :aggregate_failures do
      result = run_on_ci(breached)
      expect([result.status, result.pending_exception]).to match([:pending, be_a(WallClock::Breach)])
      expect(CiSkipBackstop.offenders([breached])).to eq([])
    end

    it "files one finding naming the measurement and the stretched bound" do
      run_on_ci(breached)
      expect(File.readlines(findings).map { |line| JSON.parse(line)["said"] }).to match([/5\.0 is not under 4\.0/])
    end
  end
end
