require "spec_helper"
require "json"
require_relative "support/registry_double"
require "hecks/hecks/adapters/dispatching"

# Filling the Work queue: which planned rows start a session, why each other waits, and the dry run
# that starts nothing. Rows, load and the launcher are stand-ins; no session is ever started.
RSpec.describe Hecks::Adapters::Dispatching do
  include RegistryDouble

  let(:plan_class) { described_class::Plan }
  let(:calls) { [] }

  def row(key, *area) = plan_class::Row.new(key: key, title: "Title #{key}", detail: "detail", area: area)

  def plan(planned, started: [], **limits)
    plan_class.new(planned, started, cap: 8, load: 1.0, max_load: 4.0, frozen: [], **limits)
  end

  def reasons(result) = result.skipped.to_h { |skip| [skip.key, skip.reason] }

  def rows_double(planned, started = [])
    instance_double(described_class::Rows, planned: planned, started: started, runs: {})
  end

  def result(out, err, success)
    Hecks::Adapters::Shell::Result.new(out, err, instance_double(Process::Status, success?: success))
  end

  def runner = ->(argv) { (calls << argv) && result(reply(argv), "", true) }

  def reply(argv)
    return "" unless argv[1] == "Brief.compose!"

    state = { "outcome" => "Title a", "rules" => "RULES {work}", "freeze" => "FREEZE:", "coordination" => "COORD:" }
    JSON.generate("state" => state)
  end

  def adapter(planned, started: [], **standins)
    described_class.new(settings: { load: -> { 1.5 }, cpus: 4, rows: rows_double(planned, started), runner: runner, **standins })
  end

  def report(held)
    planned, started = held[:rows]
    adapter(planned, started: started || [], **held.fetch(:standins, {})).choose(**held[:record]).dig(:report, :value)
  end

  it "skips a row whose area overlaps a started row's, naming the holder and the path" do
    outcome = plan([row("b", "lib/a/x.rb")], started: [row("a", "lib/a")])

    expect(reasons(outcome)).to eq("b" => "skipped: lib/a/x.rb overlaps a at lib/a")
  end

  it "stops at the cap and holds back every row after it" do
    outcome = plan([row("a", "x"), row("b", "y"), row("c", "z")], started: [row("s", "w")], cap: 2)

    expect([outcome.chosen.map(&:key), reasons(outcome).keys]).to eq([["a"], %w[b c]])
  end

  it "skips a row in a frozen area" do
    outcome = plan([row("a", "lib/hecks/quality_control/x.rb"), row("b", "lib/other")], frozen: ["QualityControl"])

    expect([outcome.chosen.map(&:key), reasons(outcome)["a"]]).to eq([["b"], "skipped: frozen (QualityControl)"])
  end

  it "starts nothing while the load is above the limit" do
    outcome = plan([row("a", "x")], load: 23.4, max_load: 12.0)

    expect(reasons(outcome)).to eq("a" => "skipped: load 23.4 > 12.0")
  end

  it "lets a row with no area start beside any other" do
    expect(plan([row("a")], started: [row("s", "lib")]).chosen.map(&:key)).to eq(["a"])
  end

  describe "the dry run" do
    let(:held) { { rows: [[row("a", "lib/a"), row("b", "lib/a/b")]], record: { repo: "/repo" } } }

    it "says the load and what would start, and why the rest waits", :aggregate_failures do
      text = report(held)

      expect(text).to include("load 1.5 (limit 4.0, 4 cpus)", "would start a: Outcome: Title a")
      expect(text).to include("b skipped: lib/a/b overlaps a at lib/a")
    end

    it "runs no command" do
      report(held)

      expect(calls).to be_empty
    end
  end

  describe "with confirm" do
    let(:held) { { rows: [[row("a", "lib/a")], [row("s", "lib/s")]], record: { repo: "/repo", confirm: { value: true } } } }

    it "starts the row, composes its brief and hands it to a session, in that order" do
      report(held)

      commands = calls.map { |argv| argv.find { |word| word.end_with?("!") } }

      expect(commands).to eq(["LinkedTree.pull_main!", "Work.start!", "Brief.compose!", "AgentRun.dispatch!"])
    end

    it "briefs the session with the other started rows' areas to leave alone", :aggregate_failures do
      report(held)
      brief = calls.last.find { |word| word.start_with?("brief.value=") }

      expect(brief).to include("RULES a", "COORD:", "- s: Title s (lib/s)")
      expect(brief).not_to include("FREEZE:")
    end

    it "yields the row back to the plan when a step fails" do
      failing = ->(argv) { result("", "no", argv[1] != "Work.start!") }

      expect(report(held.merge(standins: { runner: failing }))).to include("yielded a: start of a failed")
    end
  end
end
