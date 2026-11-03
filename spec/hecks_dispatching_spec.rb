require "spec_helper"
require "json"
require_relative "support/registry_double"
require "hecks/hecks/adapters/dispatching"

# Filling the Work queue: which planned work items start a session, why each other waits, and the
# dry run
# that starts nothing. Work items, load and the launcher are stand-ins; no session is ever started.
RSpec.describe Hecks::Adapters::Dispatching do
  include RegistryDouble

  let(:plan_class) { described_class::Plan }
  let(:calls) { [] }

  def item(key, *area) = plan_class::Item.new(key: key, title: "Title #{key}", detail: "detail", area: area)

  def plan(planned, started: [], **limits)
    plan_class.new(planned, started, cap: 8, load: 1.0, max_load: 4.0, frozen: [], **limits)
  end

  def reasons(result) = result.skipped.to_h { |skip| [skip.key, skip.reason] }

  def work_items_double(planned, started = [])
    instance_double(described_class::WorkItems, planned: planned, started: started, runs: {}, lessons: [])
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
    items = work_items_double(planned, started)
    described_class.new(settings: { load: -> { 1.5 }, cpus: 4, work_items: items, runner: runner, **standins })
  end

  def report(held)
    planned, started = held[:work_items]
    adapter(planned, started: started || [], **held.fetch(:standins, {})).choose(**held[:record]).dig(:report, :value)
  end

  it "skips a work item whose area overlaps a started work item's, naming the holder and the path" do
    outcome = plan([item("b", "lib/a/x.rb")], started: [item("a", "lib/a")])

    expect(reasons(outcome)).to eq("b" => "skipped: lib/a/x.rb overlaps a at lib/a")
  end

  it "stops at the cap and holds back every work item after it" do
    outcome = plan([item("a", "x"), item("b", "y"), item("c", "z")], started: [item("s", "w")], cap: 2)

    expect([outcome.chosen.map(&:key), reasons(outcome).keys]).to eq([["a"], %w[b c]])
  end

  it "skips a work item in a frozen area" do
    outcome = plan([item("a", "lib/hecks/quality_control/x.rb"), item("b", "lib/other")], frozen: ["QualityControl"])

    expect([outcome.chosen.map(&:key), reasons(outcome)["a"]]).to eq([["b"], "skipped: frozen (QualityControl)"])
  end

  it "starts nothing while the load is above the limit" do
    outcome = plan([item("a", "x")], load: 23.4, max_load: 12.0)

    expect(reasons(outcome)).to eq("a" => "skipped: load 23.4 > 12.0")
  end

  it "fills only the work items whose id starts with `only`, leaving the rest unread" do
    planned = [item("red-a", "x"), item("gap-a", "y"), item("gap-b", "z")]

    text = report(work_items: [planned, []], record: { only: { value: "gap-" } })

    expect(text).to include("would start gap-a", "would start gap-b").and(satisfy { |t| !t.include?("red-a") })
  end

  it "fills the whole queue when `only` is left out" do
    text = report(work_items: [[item("red-a", "x"), item("gap-a", "y")], []], record: {})

    expect(text).to include("would start red-a", "would start gap-a")
  end

  it "lets a work item with no area start beside any other" do
    expect(plan([item("a")], started: [item("s", "lib")]).chosen.map(&:key)).to eq(["a"])
  end

  it "reads a red-* work item before earlier planned work, whatever its step" do
    hecks = boot_hecks_in_memory
    %w[first red-ci-3].each do |key|
      hecks.dispatch_flat("Tickets::Work.Plan", work: { value: key }, title: { value: key }, detail: { value: "d" }, area: [])
    end

    expect(described_class::WorkItems.new(hecks.registry).planned.map(&:key)).to eq(%w[red-ci-3 first])
  end

  describe "the dry run" do
    let(:held) { { work_items: [[item("a", "lib/a"), item("b", "lib/a/b")]], record: { repo: "/repo" } } }

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
    let(:held) do
      { work_items: [[item("a", "lib/a")], [item("s", "lib/s")]], record: { repo: "/repo", confirm: { value: true } } }
    end

    it "starts the work item, composes its brief and hands it to a session, in that order" do
      report(held)

      commands = calls.map { |argv| argv.find { |word| word.end_with?("!") } }

      expect(commands).to eq(["LinkedTree.pull_main!", "Work.start!", "Brief.compose!", "AgentRun.dispatch!"])
    end

    it "briefs the session with the other started work items' areas to leave alone", :aggregate_failures do
      report(held)
      brief = calls.last.find { |word| word.start_with?("brief.value=") }

      expect(brief).to include("RULES a", "COORD:", "- s: Title s (lib/s)")
      expect(brief).not_to include("FREEZE:")
    end

    it "yields the work item back to the plan when a step fails" do
      failing = ->(argv) { result("", "no", argv[1] != "Work.start!") }

      expect(report(held.merge(standins: { runner: failing }))).to include("yielded a: start of a failed")
    end
  end
end
