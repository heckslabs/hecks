require "spec_helper"
require "json"
require "hecks/hecks/adapters/dispatching"

# A fill asked for `only=group:<path>` hands the planned work items whose areas overlap the path to
# one coder: it starts the first as the lead, holds the others in its batch, and dispatches one
# brief listing them all. The launcher's commands are answered by a stand-in runner.
RSpec.describe Hecks::Adapters::Dispatching, "a group fill" do
  let(:calls) { [] }

  def item(key, area = "lib/x/#{key}.rb", batch: "")
    described_class::Plan::Item.new(key: key, title: "Title #{key}", detail: "Detail #{key}", area: [area], batch: batch)
  end

  def runner
    lambda do |argv|
      calls << argv
      out = argv.include?("Brief.compose!") ? JSON.generate("state" => { "outcome" => "Title" }) : ""
      Hecks::Adapters::Shell::Result.new(out, "", instance_double(Process::Status, success?: true))
    end
  end

  def adapter(planned, load: 1.0)
    items = instance_double(described_class::WorkItems, planned: planned, started: [], runs: {}, lessons: [])
    described_class.new(settings: { load: -> { load }, cpus: 10, cap: 6, work_items: items, runner: runner })
  end

  def fill(planned, **opts) = adapter(planned, **opts).choose(repo: "/repo", confirm: { value: true }, only: "group:lib/x")

  def named(verb) = calls.select { |argv| argv.include?(verb) }

  def three = [item("a"), item("b"), item("c", "lib/x"), item("z", "lib/z/z.rb")]

  it "starts one session for a group of three, holding the other two in the lead's batch", :aggregate_failures do
    text = fill(three).dig(:report, :value)

    expect(text).to include("starting group lib/x (3 items): started a")
    expect(named("Work.start!").size).to eq(1)
    expect(named("Work.enlist!").map { |argv| argv[2] }).to eq(%w[to=b to=c])
    expect(named("AgentRun.dispatch!").size).to eq(1)
  end

  it "lists every work item of the batch in plan order in the one brief" do
    fill(three)
    brief = named("AgentRun.dispatch!").first.find { |word| word.start_with?("brief.value=") }

    expect(brief).to match(/1\. a: Title a\n   Detail a\n2\. b: Title b\n   Detail b\n3\. c: Title c/)
  end

  it "claims the union of the group's areas for the lead" do
    fill(three)

    areas = named("Work.start!").first.grep(/\Aarea\.value=/)

    expect(areas).to eq(%w[area.value=lib/x/a.rb area.value=lib/x/b.rb area.value=lib/x])
  end

  it "splits a group over the cap: the first six form the batch and the rest stay planned" do
    eight = %w[a b c d e f g h].map { |key| item(key) }
    preview = adapter(eight).preview(repo: "/repo", only: "group:lib/x")[:text]

    expect(preview).to include("would start group lib/x (6 items)")
  end

  it "says a group is held, and why, when the load is over its limit" do
    text = adapter(three, load: 11.0).preview(repo: "/repo", only: "group:lib/x")[:text]

    expect(text).to include("group lib/x (3 items) held: load 11.0 > 10.0")
  end
end

# A started batch is one session: its members wait for its lead and do not take places under the
# cap, so other work still starts beside it.
RSpec.describe Hecks::Adapters::Dispatching::Plan, "with a batch started" do
  def item(key, area, batch: "") = described_class::Item.new(key: key, title: key, area: [area], batch: batch)

  def lead = item("a", "lib/x")

  def members = %w[b c d e f].map { |key| item(key, "lib/x/#{key}.rb", batch: "a") }

  def plan = described_class.new([*members, item("z", "lib/z")], [lead], cap: 2, load: 1.0, max_load: 10.0, frozen: [])

  it "counts a group of six as one session against the cap, so another item starts" do
    expect(plan.chosen.map(&:key)).to eq(%w[z])
  end

  it "holds each member of the batch for its lead" do
    expect(plan.skipped.map(&:reason).uniq).to eq(["skipped: held: in the batch of a"])
  end
end
