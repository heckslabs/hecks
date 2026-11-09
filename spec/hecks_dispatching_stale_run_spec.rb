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
  def runner(dispatches, retire: result(""))
    lambda do |argv|
      calls << argv
      name = argv.find { |word| word.end_with?("!") }
      case name
      when "AgentRun.dispatch!" then dispatches.size > 1 ? dispatches.shift : dispatches.first
      when "Brief.compose!" then result(brief)
      when "AgentRun.retire!" then retire
      else result("")
      end
    end
  end

  def names = calls.filter_map { |argv| argv.find { |word| word.end_with?("!") } }

  def launch(*dispatches, retire: result(""))
    described_class.new("/repo", runner: runner(dispatches, retire: retire)).launch(item, held: [], minutes: 30)
  end

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

  it "does not dispatch again when the retire is refused, and says why", :aggregate_failures do
    refused = result("", "[refused] AgentRun a is not started", success: false)
    line = launch(result("", taken, success: false), result("{}"), retire: refused)

    expect(names.count("AgentRun.dispatch!")).to eq(1)
    expect(line).to include("retire of a refused", "is not started")
  end

  it "keeps the key held as a held key when the retire is refused", :aggregate_failures do
    refused = result("", "[refused] gone", success: false)
    yield_line = calls_of_yield { launch(result("", taken, success: false), retire: refused) }

    expect(yield_line).to include("yield_kind.value=already_recorded")
  end

  # The `Work.yield!` line the launch ended with.
  def calls_of_yield
    yield
    calls.find { |argv| argv.include?("Work.yield!") }
  end
end
