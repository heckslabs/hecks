require "spec_helper"
require "json"
require "hecks/hecks/adapters/dispatching"

# A fill asked for `only=group:<path>` hands the planned work items whose areas overlap the path to
# one coder: it starts the first as the lead, holds the others in its batch, and dispatches one
# brief listing them all. The launcher's commands are answered by a stand-in runner.
RSpec.describe Hecks::Adapters::Dispatching, "#choose" do
  let(:calls) { [] }

  def item(key, area = "lib/x/#{key}.rb", batch: "", commit: "")
    described_class::Plan::Item.new(key: key, title: "Title #{key}", detail: "Detail #{key}", area: [area], batch: batch,
                                    batch_commit: commit)
  end

  def runner
    lambda do |argv|
      calls << argv
      out = argv.include?("Brief.compose!") ? JSON.generate("state" => { "outcome" => "Title" }) : ""
      Hecks::Adapters::Shell::Result.new(out, "", instance_double(Process::Status, success?: true))
    end
  end

  def adapter(planned, load: 1.0, batched: [])
    items = instance_double(described_class::WorkItems, planned: planned, batched: batched, started: [], runs: {}, lessons: [])
    described_class.new(settings: { sprint: false, load: -> { load }, cpus: 10, cap: 6, work_items: items, runner: runner })
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

  def committed_to(lead) = item("m#{lead}", batch: lead, commit: "abc123")

  it "resumes a group under the work item that already leads members committed on its branch" do
    preview = adapter(three, batched: [committed_to("b")]).preview(repo: "/repo", only: "group:lib/x")[:text]

    expect(preview).to include("would start group lib/x (3 items): Outcome: Title b")
  end

  it "resumes under the first in plan order when two work items lead committed members" do
    preview = adapter(three, batched: [committed_to("c"), committed_to("b")]).preview(repo: "/repo", only: "group:lib/x")[:text]

    expect(preview).to include("would start group lib/x (3 items): Outcome: Title b")
  end
end
