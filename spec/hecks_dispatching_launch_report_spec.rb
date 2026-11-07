require "spec_helper"
require "json"
require "hecks/hecks/adapters/dispatching"

# A confirmed filling says, for each work item it chose, that the item started or why it went back
# to the plan. The launcher's commands are answered by a stand-in runner; no session starts.
RSpec.describe Hecks::Adapters::Dispatching, "#choose" do
  WARNING = "[hecks] QualityControl declares process_manager(s) BugCiWatch but its resolved persistence " \
            "adapter has no save_saga\n".freeze

  let(:calls) { [] }

  def item(key) = described_class::Plan::Item.new(key: key, title: "Title #{key}", detail: "", area: [key])

  def result(out, err = "", success: true)
    Hecks::Adapters::Shell::Result.new(out, err, instance_double(Process::Status, success?: success))
  end

  def brief = JSON.generate("state" => { "outcome" => "Title", "rules" => "RULES" })

  # The runner: compose prints a brief, `answers` overrides any command by its name.
  def runner(answers)
    lambda do |argv|
      calls << argv
      name = argv.find { |word| word.end_with?("!") }
      reply = answers.fetch(name) { result(name == "Brief.compose!" ? brief : "") }
      reply.is_a?(Proc) ? reply.call(argv) : reply
    end
  end

  def report(keys, answers = {})
    items = instance_double(described_class::WorkItems, planned: keys.map { |key| item(key) }, started: [], runs: {},
                                                        lessons: [])
    adapter = described_class.new(settings: { load: -> { 1.0 }, cpus: 4, work_items: items, runner: runner(answers) })
    adapter.choose(repo: "/repo", confirm: { value: true }).dig(:report, :value)
  end

  def started_but_refused
    state = JSON.generate("state" => { "work" => "a", "status" => "started" })
    reason = "reaction DispatchWhenWorkStarted was refused (Pipeline::Passage.Dispatch): no Passage"
    result(state, "#{WARNING}#{reason}\n", success: false)
  end

  it "starts a work item whose start reached started though a later reaction was refused", :aggregate_failures do
    text = report(["a"], "Work.start!" => started_but_refused)

    expect(text).to include("started a (then refused: reaction DispatchWhenWorkStarted was refused")
    expect(calls.map { |argv| argv.find { |word| word.end_with?("!") } }).to include("AgentRun.dispatch!")
  end

  it "yields a work item with the command's real reason, not the boot warning", :aggregate_failures do
    text = report(["a"], "AgentRun.dispatch!" => result("", "#{WARNING}AgentRun cannot start: repo missing", success: false))

    expect(text).to include("yielded a: dispatch of a failed: AgentRun cannot start: repo missing")
    expect(text).not_to include("process_manager")
  end

  it "yields a work item with the record's refusal when the command printed one" do
    refused = result(JSON.generate("state" => { "status" => "planned" }, "refusal" => "area held by b"), WARNING, success: false)

    expect(report(["a"], "Work.start!" => refused)).to include("yielded a: start of a failed: area held by b")
  end

  it "yields a work item whose compose printed no brief" do
    expect(report(["a"], "Brief.compose!" => result("no json here"))).to include("yielded a: compose of a printed no brief")
  end

  it "says why for each chosen item, starting the next after one whose launch raised", :aggregate_failures do
    raising = ->(argv) { argv.include?("run.value=a") ? raise(ArgumentError, "bad brief") : result("") }
    text = report(%w[a b], "AgentRun.dispatch!" => raising)

    expect(text).to include("yielded a: ArgumentError: bad brief", "started b")
    expect(text).not_to include("would start")
  end

  it "names a work item that could neither start nor be yielded" do
    failing = ->(_argv) { raise IOError, "closed" }
    text = report(["a"], "LinkedTree.pull_main!" => failing, "Work.yield!" => failing)

    expect(text).to include("a could not be started or yielded: IOError: closed")
  end
end
