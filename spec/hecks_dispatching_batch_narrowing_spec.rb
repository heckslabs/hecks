require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A confirmed fill narrows the stored claim of a started batch lead to the ground it holds now, so
# the WorkAreas port and a landing's clash check stop reading a committed member's area.
RSpec.describe Hecks::Adapters::Dispatching, "#choose narrowing a batch lead" do
  let(:calls) { [] }

  def item(key, area, batch: "", commit: "")
    described_class::Plan::Item.new(key: key, title: key, area: area, batch: batch, batch_commit: commit)
  end

  def runner
    lambda do |argv|
      calls << argv
      Hecks::Adapters::Shell::Result.new("", "", instance_double(Process::Status, success?: true))
    end
  end

  def members = [item("b", %w[lib/x/b], batch: "a", commit: "abc123"), item("c", %w[lib/x/c], batch: "a")]

  def adapter
    lead = described_class::Plan::Item.new(key: "a", title: "a", area: %w[lib/x/a.rb lib/x/b lib/x/c], batched: members)
    items = instance_double(described_class::WorkItems, planned: [], started: [lead],
                                                        runs: {}, lessons: [], claimant: "owner")
    described_class.new(settings: { load: -> { 1.0 }, cpus: 10, cap: 6, work_items: items, runner: runner,
                                    effective: lambda(&:area), sessions: [] })
  end

  it "rescopes the lead to its own area and the members still to be built" do
    adapter.choose(repo: "/repo", confirm: { value: true }, only: "nothing")
    rescope = calls.find { |argv| argv.include?("Work.rescope!") }

    expect(rescope.grep(/\Aarea\.value=/)).to eq(%w[area.value=lib/x/a.rb area.value=lib/x/c])
  end
end
