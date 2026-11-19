require "spec_helper"
require "json"
require "hecks/tickets/bluebook/adapters/work_show"

# A work item and a decision record keep the interview and Point they came from, and planning or
# drafting a key that exists is refused by name, so replaying an interview makes no duplicate. The
# decisions are drafted into Memory: a DecisionFiles store reads docs/decisions and has no citation.
RSpec.describe "a Tickets work item and decision citing an interview" do
  let(:root) { InMemoryDomain::ROOT }
  let(:registry) { Hecks::Runtime::Registry.new }

  let(:runtime) do
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER].each { |file| Kernel.load(file) }
      %w[coder/coder.bluebook coder/coder.hecksagon tickets/bluebook/tickets.bluebook
         tickets/bluebook/tickets.hecksagon].each { |file| Kernel.load(File.join(root, "lib/hecks", file)) }
    end
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:citation) { { interview: { value: "2026-11-07-tools" }, point: { value: "p3" } } }

  def plan(key, **extra)
    runtime
    Tickets::Work.plan!(work: { value: key }, title: { value: "Retire #{key}" }, **extra)
  end

  def draft(number, **extra)
    runtime
    Tickets::Adr.draft!(adr: { value: number }, title: { value: "Decision #{number}" }, **extra)
  end

  def shown(key) = JSON.parse(Hecks::Adapters::WorkShow.new(registry: registry).show(work: key)[:text])

  it "shows the interview and Point a planned work item cites" do
    plan("cite/a", **citation)

    expect(shown("cite/a").values_at("interview", "point")).to eq(%w[2026-11-07-tools p3])
  end

  it "shows an empty citation for a work item planned from no interview" do
    plan("cite/b")

    expect(shown("cite/b").values_at("interview", "point")).to eq(["", ""])
  end

  it "keeps the interview and Point a drafted decision cites", :aggregate_failures do
    draft("9194", **citation)
    record = Tickets::Adr.find("9194")

    expect([record.interview.value, record.point.value]).to eq(%w[2026-11-07-tools p3])
  end

  it "refuses planning a work key that exists, by name" do
    plan("cite/c", **citation)

    expect { plan("cite/c", **citation) }.to raise_error(Hecks::Runtime::AlreadyExists, %r{Work.*already exists.*cite/c})
  end

  it "refuses planning the key of a finished work item" do
    plan("cite/d")
    Tickets::Work.find("cite/d").finish!

    expect { plan("cite/d") }.to raise_error(Hecks::Runtime::AlreadyExists, %r{cite/d})
  end

  it "refuses drafting a decision number that exists, by name" do
    draft("9195")

    expect { draft("9195", **citation) }.to raise_error(Hecks::Runtime::AlreadyExists, /Adr.*already exists.*9195/)
  end
end
