require "spec_helper"
require "json"
require "hecks/hecks/adapters/dispatching"

# The tickets two racing fills share: a start moves the planned item to started and refuses a
# started one as the lifecycle does, with the interpreter's warnings before the refusal on stderr.
class SecondStartTickets
  WARNINGS = "/repo/lib/hecks/version.rb:4: warning: already initialized constant Hecks::VERSION\n" \
             "/gems/hecks/lib/hecks/version.rb:4: warning: previous definition of VERSION was here\n".freeze

  REFUSAL = "[LifecycleRefused] Work.Start refused — status is started, and Start moves it only from planned".freeze

  BRIEF = JSON.generate("state" => { "outcome" => "Title", "rules" => "RULES" })

  attr_reader :calls

  def initialize
    @calls = []
    @status = "planned"
  end

  def call(argv)
    name = argv.find { |word| word.end_with?("!") }
    calls << name
    return start if name == "Work.start!"

    result(name == "Brief.compose!" ? BRIEF : "")
  end

  private

  def start
    return result("", "#{WARNINGS}#{REFUSAL}\n", success: false) if @status == "started"

    @status = "started"
    result(JSON.generate("state" => { "work" => "a", "status" => "started" }))
  end

  def result(out, err = "", success: true)
    Hecks::Adapters::Shell::Result.new(out, err, Struct.new(:success?).new(success))
  end
end

# Two fills that race for one work item leave it started once: the second fill's `Work.start!` is
# refused because the item is already started, and that fill leaves the item to the first one's
# claim instead of yielding it. No session starts.
RSpec.describe Hecks::Adapters::Dispatching::Launcher, "#attempt on a started work item" do
  let(:tickets) { SecondStartTickets.new }
  let(:item)    { Hecks::Adapters::Dispatching::Plan::Item.new(key: "a", title: "Title a", detail: "", area: ["a"]) }

  def race = Array.new(2) { described_class.new("/repo", runner: tickets).attempt(item, held: [], minutes: 60) }

  it "starts the item in the first fill and leaves it to that claim in the second" do
    expect(race.map(&:first)).to eq(%i[started held])
  end

  it "never yields, composes or dispatches a second time for the started item", :aggregate_failures do
    race
    expect(tickets.calls.count("Work.yield!")).to eq(0)
    expect(tickets.calls.count("AgentRun.dispatch!")).to eq(1)
    expect(tickets.calls.last(2)).to eq(["LinkedTree.pull_main!", "Work.start!"])
  end

  it "says the second fill left the item because it is already started" do
    expect(race.last.last).to eq("a is already started: its claim stands, so this fill leaves it")
  end
end
