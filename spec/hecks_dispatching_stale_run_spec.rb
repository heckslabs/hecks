require "spec_helper"
require "json"
require "hecks/hecks/adapters/dispatching"

# A dispatch refused because a run still recorded started holds the key retires that run when its
# session is gone, and dispatches once more. The launcher's commands are answered by a stand-in
# runner; no session starts and no run is touched.
RSpec.describe Hecks::Adapters::Dispatching::Launcher do
  let(:calls) { [] }
  let(:item) { Hecks::Adapters::Dispatching::Plan::Item.new(key: "a", title: "A", detail: "", area: []) }
  let(:taken) { "[already_recorded] refused: run a is already recorded with other arguments: nothing written" }

  def result(out, err = "", success: true)
    Hecks::Adapters::Shell::Result.new(out, err, instance_double(Process::Status, success?: success))
  end

  def brief = JSON.generate("state" => { "outcome" => "A", "rules" => "RULES" })

  # Dispatch answers each reply in turn, then the last one for any further call.
  def runner(dispatches)
    lambda do |argv|
      calls << argv
      name = argv.find { |word| word.end_with?("!") }
      case name
      when "AgentRun.dispatch!" then dispatches.size > 1 ? dispatches.shift : dispatches.first
      when "Brief.compose!" then result(brief)
      else result("")
      end
    end
  end

  def names = calls.filter_map { |argv| argv.find { |word| word.end_with?("!") } }

  def launch(*dispatches) = described_class.new("/repo", runner: runner(dispatches)).launch(item, held: [], minutes: 30)

  it "retires the run whose session is gone and dispatches again", :aggregate_failures do
    line = launch(result("", taken, success: false), result("{}"))

    expect(line).to eq("started a")
    expect(names.grep(/AgentRun/)).to eq(%w[AgentRun.dispatch! AgentRun.retire! AgentRun.dispatch!])
  end

  it "asks to retire the run named for the work item" do
    launch(result("", taken, success: false), result("{}"))

    expect(calls.find { |argv| argv.include?("AgentRun.retire!") }).to include("to=a")
  end

  it "yields the work item when the session is still listed and the key stays held", :aggregate_failures do
    line = launch(result("", taken, success: false))

    expect(line).to start_with("yielded a: dispatch of a failed")
    expect(names.count("AgentRun.dispatch!")).to eq(2)
  end

  it "does not retire anything for a refusal that is not a held key", :aggregate_failures do
    line = launch(result("", "no brief", success: false))

    expect(line).to start_with("yielded a")
    expect(names).not_to include("AgentRun.retire!")
  end
end
