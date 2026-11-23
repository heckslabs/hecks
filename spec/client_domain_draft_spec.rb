require "spec_helper"
require "hecks/clients/draft"
require_relative "support/scripted_proposer"
require_relative "fixtures/clients/bakery/turns"
require_relative "fixtures/clients/bakery/proposals"

# Steps of the bakery draft: the made-up client's turns recorded, then drafted from.
module ClientDomainDraftSteps
  def dispatch
    ->(name, **attrs) { hecks.dispatch_flat(name, **attrs) }
  end

  def record_turns
    BakeryDraft::TURNS.each_with_index do |(speaker, words), index|
      opening = index.zero? ? { subject: { value: "Orders" }, keeping: { value: "local" } } : {}
      hecks.dispatch_flat("Interviews::Interview.Record", reference: { value: "BAKE-1" }, **opening,
                                                         speaker: { value: speaker }, answer: { value: words })
    end
  end

  def state
    aggregate = hecks.registry.bluebook("Interviews").aggregate("Interview")
    Hecks::Runtime::Value.materialize(hecks.registry.repository("Interviews", aggregate).find("BAKE-1").state)
  end

  def propose_all
    (1..BakeryDraft::TURNS.size).each { |n| draft.turn(state[:exchanges][n - 1], n) }
  end

  def accept_where
    state[:points].select { |p| yield(p[:kind][:value], p[:statement][:value]) }
                  .each { |p| draft.accept(p[:number][:value]) }
  end
end

RSpec.describe Hecks::Clients::Draft::DomainDraft do
  include ClientDomainDraftSteps

  let(:hecks) { Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/interviews"), install_driving: false) }
  let(:draft) { described_class.new(proposer: ScriptedProposer.new(BakeryDraft::PROPOSALS), dispatch: dispatch, reference: "BAKE-1") }
  let(:draft_text) { draft.text(subject: "Orders", interview: state) }

  before { record_turns }

  it "proposes Points that cite the exchange they came from" do
    propose_all
    expect(state[:points].map { |p| [p[:statement][:value], p[:source][:value]] }.first(2))
      .to eq([["Order", 2], ["Order: Place -> Placed", 2]])
  end

  it "leaves a turn past the exchanges recorded to the domain to refuse" do
    far = described_class.new(proposer: ScriptedProposer.new(7 => [["thing", "Ghost"]]), dispatch: dispatch,
                              reference: "BAKE-1")
    expect { far.turn({}, 7) }.to raise_error(StandardError, /exchange/i)
  end

  it "leaves a rejected Point out of the text" do
    propose_all
    accept_where { |_, s| s != "Paperbook" }
    draft.reject(3)
    expect(draft_text).not_to include("Paperbook")
  end

  def accept_the_draft
    propose_all
    accept_where { |kind, words| %w[thing action rule].include?(kind) && words != "Paperbook" }
  end

  it "drafts Order, Loaf and Bake in the client's words" do
    accept_the_draft
    expect(draft_text).to include('aggregate "Order"', 'aggregate "Loaf"', 'command "Bake"',
                                  '# "A list of loaves, and a few cakes now and then."')
  end

  it "stages the draft clean" do
    accept_the_draft
    expect(draft.check(subject: "Orders", interview: state)[:verdict].clean).to be(true)
  end

  it "keeps Hecks Tickets empty when work and decision Points are accepted on a client interview" do
    propose_all
    accept_where { |kind, _| %w[work decision].include?(kind) }
    expect(hecks.registry.event_log.map(&:name)).not_to include(match(/Work|Adr/))
  end
end
