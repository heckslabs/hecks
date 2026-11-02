require "spec_helper"
require "tmpdir"
require "hecks/quality_control/cli/qa_tick"

# The tick's quiesce guard with every step stubbed: no real step runs, no ledger is touched.
# rubocop:disable-next RSpec/MultipleMemoizedHelpers, RSpec/ExampleLength
RSpec.describe "hecks quality_control tick while quiesced", :aggregate_failures do
  let(:dir) { Dir.mktmpdir("qa_tick_quiesce") }
  let(:path) { File.join(dir, "quiesce") }
  let(:marker) { Hecks::Adapters::QaQuiesceMarker.new(path: path) }
  let(:tick) { Hecks::QualityControlCli::QaTick.new(root: dir, env: {}) }
  let(:ran) { [] }
  let(:steps) do
    %w[pr_check sweep generated_domains mutation main_check push_nudge event_pump]
  end

  before do
    allow(Hecks::Adapters::QaQuiesceMarker).to receive(:new).and_return(marker)
    allow(tick).to receive(:dial) { |name, _fallback| name != :QUIESCED }
    allow(tick).to receive(:banner)
    steps.each do |name|
      allow(tick).to receive(:"run_#{name}") do
        ran << name
        ["ran #{name}", 0]
      end
    end
  end

  after { FileUtils.remove_entry(dir) }

  def run_all = tick.send(:finding_steps)

  it "runs every step when nothing is held" do
    results = nil
    expect { results = run_all }.not_to output(/quiesced/).to_stdout

    expect(results.map(&:exit_code).uniq).to eq([0])
    expect(ran.size).to eq(8)
  end

  it "skips each step with the message and exit 0 while held, and runs them again after release" do
    marker.hold!(owner: "mint", reason: "window")
    results = nil
    output = capture_stdout { results = run_all }

    expect(ran).to be_empty
    expect(results.map(&:exit_code).uniq).to eq([0])
    results.each { |step| expect(output).to include("quiesced: skipped #{step.name}") }
    expect(results.size).to eq(8)

    marker.release!(owner: "mint")
    run_all
    expect(ran.size).to eq(8)
  end

  it "notices a hold set while the tick runs, before the next step" do
    allow(tick).to receive(:run_sweep) do
      marker.hold!(owner: "mint", reason: "mid-tick")
      ["swept", 0]
    end
    results = nil
    output = capture_stdout { results = run_all }

    expect(ran).to eq(["pr_check"])
    expect(results[1].output).to eq("swept")
    expect(output).to include("quiesced: skipped check_generated_domains --from-dials")
  end

  it "ignores a stale marker, runs the steps and reports the stale marker once" do
    marker.hold!(owner: "crashed", reason: "old")
    old = Time.now - (3 * 3600)
    File.utime(old, old, path)
    File.write(path, JSON.generate(owner: "crashed", reason: "old", held_at: old.utc.iso8601))
    output = capture_stdout { run_all }

    expect(ran.size).to eq(8)
    expect(output.scan("quiesce marker is stale and ignored").size).to eq(1)
    expect(output).not_to include("quiesced: skipped")
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
