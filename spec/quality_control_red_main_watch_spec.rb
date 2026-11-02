require "spec_helper"
require "json"
require "hecks/hecks/adapters/dispatching"
require "hecks/quality_control/cli/qa_red_main_watch"

# Red main as a standing Work row: the tick's watch files one `red-main-<run id>` row when the
# latest CI run on main failed and finishes it when a later run passes, the dispatch fill starts
# it first, and `push_rehearsal.due` and the train's report lead with it without ever refusing a
# push. The GitHub reader is a stub, the Hecks domain boots in Memory, and no network or git
# history is read.
RSpec.describe "red main as a standing Work row" do
  let(:hecks) { boot_hecks_in_memory }
  let(:registry) { hecks.registry }
  let(:run_class) { Hecks::Adapters::MainCiReader::Run }
  let(:reader) { instance_double(Hecks::Adapters::MainCiReader) }

  def ci_run(id, conclusion, job: nil)
    run_class.new(id: id.to_s, conclusion: conclusion, created_at: "2026-11-01T06:24:32Z", sha: "16ce91812", failed_job: job)
  end

  def watch(*runs)
    allow(reader).to receive(:runs).and_return(runs)
    expect { Hecks::QualityControlCli::QaRedMainWatch.new(runtime: hecks, reader: reader).call }.to output.to_stdout
  end

  def plan_row(key, step: nil)
    hecks.dispatch_flat("Tickets::Work.Plan", work: { value: key }, title: { value: key }, detail: { value: "d" },
                                              step: step && { value: step }, area: [])
  end

  def red_line = Hecks::Adapters::RedMainLine.lead(registry)

  def open_red = Hecks::Adapters::RedMainLine.open_rows(registry).map { |row| row[:id].to_s }

  it "files one row naming the failing job when the latest CI run failed", :aggregate_failures do
    watch(ci_run(41_280_710_646, "failure", job: "release_consistency"))

    expect(open_red).to eq(["red-main-41280710646"])
    expect(Hecks::Adapters::RedMainLine.lead(registry))
      .to eq("main is red since 2026-11-01T06:24:32Z: release_consistency; row red-main-41280710646\n")
  end

  it "files nothing on a second tick over the same run" do
    run = ci_run(7, "failure", job: "checks_static")
    watch(run)
    watch(run)

    expect(open_red).to eq(["red-main-7"])
  end

  it "keeps one open row when a newer run fails, finishing the older one" do
    watch(ci_run(7, "failure", job: "a"))
    watch(ci_run(8, "failure", job: "b"), ci_run(7, "failure", job: "a"))

    expect(open_red).to eq(["red-main-8"])
  end

  it "finishes the row when a later run passes" do
    watch(ci_run(7, "failure", job: "a"))
    watch(ci_run(9, "success"), ci_run(7, "failure", job: "a"))

    expect(open_red).to be_empty
  end

  it "files nothing while main is green, and leaves the row when the latest run was cancelled", :aggregate_failures do
    watch(ci_run(5, "success"))
    expect(open_red).to be_empty

    watch(ci_run(6, "failure", job: "a"))
    watch(ci_run(7, "cancelled"), ci_run(6, "failure", job: "a"))
    expect(open_red).to eq(["red-main-6"])
  end

  it "does nothing when GitHub could not be read" do
    watch

    expect(open_red).to be_empty
  end

  it "has the fill read the red row before earlier planned work, whatever its step" do
    plan_row("first", step: 1)
    plan_row("second", step: 2)
    plan_row("red-main-3")

    expect(Hecks::Adapters::Dispatching::Rows.new(registry).planned.map(&:key)).to eq(%w[red-main-3 first second])
  end

  it "has the fill start a red row first under a cap of one" do
    plan_row("a", step: 1)
    plan_row("red-main-1")
    ordered = Hecks::Adapters::Dispatching::Rows.new(registry).planned
    outcome = Hecks::Adapters::Dispatching::Plan.new(ordered, [], cap: 1, load: 1.0, max_load: 4.0, frozen: [])

    expect(outcome.chosen.map(&:key)).to eq(["red-main-1"])
  end

  describe "the push still going ahead" do
    let(:due_text) do
      "push due: yes; 27 commit(s) ahead of origin/main; oldest unpushed 1.0 hours old; " \
        "last rehearsal: green on abc1234 (the current main)"
    end

    before do
      watch(ci_run(7, "failure", job: "checks_static"))
      allow(Hecks::Adapters::GitRehearsal::Due).to receive(:new)
        .and_return(instance_double(Hecks::Adapters::GitRehearsal::Due, report: due_text))
    end

    it "leads the due answer with the red line and still says push due", :aggregate_failures do
      text = Hecks::Runtime::Asking.with(registry) do
        Hecks::Adapters::GitRehearsal.new.due(checkout: InMemoryDomain::ROOT).fetch(:text)
      end

      expect(text.lines.first).to start_with("main is red since 2026-11-01T06:24:32Z: checks_static; row red-main-7")
      expect(text.lines.last).to start_with("push due: yes")
    end

    it "reads the push as due for the nudge, the red line ahead of it", :aggregate_failures do
      stub = instance_double(Hecks::Adapters::GitRehearsal, due: { text: "#{red_line}#{due_text}" })
      answer = Hecks::Runtime::Asking.with(registry) { Hecks::Adapters::PushDueReader.new(rehearsal: stub).read }

      expect(answer[:due]).to eq({ value: "yes" })
      expect(answer[:detail][:value]).to start_with("yes; 27 commit(s) ahead")
    end

    it "opens the train's report with the red line and does not refuse", :aggregate_failures do
      carried = [{ report: { value: "pushed" } }, "a" * 40]
      train = Hecks::Adapters::GitTrain.new
      report = Hecks::Runtime::Asking.with(registry) { train.send(:after_mint, "minted", "a" * 40, carried) }.dig(:report, :value)

      expect(report).to start_with("main is red since")
      expect(report).to end_with("minted, then boarded aaaaaaaaa: pushed")
    end
  end
end
