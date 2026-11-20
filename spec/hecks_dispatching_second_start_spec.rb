require "spec_helper"
require "json"
require "hecks/hecks/adapters/dispatching"
require "hecks/runtime/refusal_wording"

# The stand-ins of the second-start spec, kept in a module so their constants are its own.
module SecondStart
  # The interpreter's warnings a launch prints before its own words on stderr.
  WARNINGS = "/repo/lib/hecks/version.rb:4: warning: already initialized constant Hecks::VERSION\n" \
             "/gems/hecks/lib/hecks/version.rb:4: warning: previous definition of VERSION was here\n".freeze

  # The lifecycle's refusal of a Start on a work item already at `current`, as the launcher prints
  # it: the refusal's code in brackets, then the runtime's own `transition_blocked` wording.
  #
  # @param current [String] the status the work item already holds
  # @return [String] the refusal line, such as
  #   `[lifecycle_refused] Start refused — status is "started"`
  def self.refusal(current)
    error = Hecks::Runtime::LifecycleRefused.new(
      Hecks::Runtime::RefusalWording.render_site("LifecycleRefused", "transition_blocked",
                                                 command: "Start", field: "status",
                                                 current: Hecks::Rendering.describe(current), allowed: ["planned"])
    )
    "[#{error.code}] #{error.message}"
  end

  # The tickets racing fills share: a start moves a planned work item to started and refuses a
  # started one as the lifecycle does, with the interpreter's warnings before the refusal.
  class Tickets
    BRIEF = JSON.generate("state" => { "outcome" => "Title", "rules" => "RULES" })

    attr_reader :calls

    def initialize
      @calls = []
      @status = Hash.new("planned")
    end

    def call(argv)
      name = argv.find { |word| word.end_with?("!") }
      calls << name
      return start(argv.find { |word| word.start_with?("to=") }.delete_prefix("to=")) if name == "Work.start!"

      result(name == "Brief.compose!" ? BRIEF : "")
    end

    private

    def start(key)
      return result("", "#{WARNINGS}#{SecondStart.refusal("started")}\n", success: false) if @status[key] == "started"

      @status[key] = "started"
      result(JSON.generate("state" => { "work" => key, "status" => "started" }))
    end

    def result(out, err = "", success: true)
      Hecks::Adapters::Shell::Result.new(out, err, Struct.new(:success?).new(success))
    end
  end
end

# Two fills that race for one work item leave it started once: the second fill's `Work.start!` is
# refused because the item is already started, and that fill leaves the item to the first one's
# claim instead of yielding it. No session starts.
RSpec.describe Hecks::Adapters::Dispatching::Launcher, "#attempt on a started work item" do
  let(:tickets) { SecondStart::Tickets.new }
  let(:items) do
    %w[a b].map { |key| Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: "Title #{key}", detail: "", area: [key]) }
  end

  def fill(chosen) = chosen.map { |item| described_class.new("/repo", runner: tickets).attempt(item, held: [], minutes: 60) }

  def race(chosen = items.first(1)) = Array.new(2) { fill(chosen) }.flatten(1)

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

  it "leaves each of the items two fills both chose started once and yields none", :aggregate_failures do
    expect(race(items).map(&:first)).to eq(%i[started started held held])
    expect(tickets.calls.count("Work.yield!")).to eq(0)
  end
end
