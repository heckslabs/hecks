require "spec_helper"
require_relative "support/epic_outcome_looks"

# Epic.revise! replaces an open epic's outcome and nothing else: the key, title, tier, measure and
# members stay. A blank outcome, an unknown epic and a complete epic are refused.
RSpec.describe "the Tickets Epic's revised outcome" do
  include_context "with an epic outcome tap"

  def plain(value) = value.respond_to?(:value) ? value.value : value

  def stored(name)
    aggregate = hecks.registry.bluebook("Tickets").aggregates.find { |declared| declared.hecks_name == name }
    hecks.registry.repository("Tickets", aggregate).all
  end

  def row = stored("Epic").find { |found| plain(found.epic) == "e1" }

  def revise(text, key = "e1") = cli("epic.revise!", "to=#{key}", "outcome.value=#{text}")

  def shape = %i[epic title tier measure measured status].map { |field| plain(row.public_send(field)) }

  before do
    epic
    cli("epic.rank!", "to=e1", "tier=3")
    cli("work.plan!", "work.value=m1", "title.value=Step")
    cli("work.assign!", "to=m1", "epic=e1")
  end

  it "replaces the outcome and keeps everything else", :aggregate_failures do
    before = shape
    revise("A new outcome")

    expect(plain(row.outcome)).to eq("A new outcome")
    expect(shape).to eq(before)
  end

  it "keeps the member joined to the epic" do
    revise("A new outcome")

    expect(plain(stored("Work").find { |work| plain(work.work) == "m1" }.epic)).to eq("e1")
  end

  it "refuses a blank outcome", :aggregate_failures do
    expect(revise("  ")).to include("an epic states its outcome")
    expect(plain(row.outcome)).to eq("It is carried out")
  end

  it "refuses an epic that does not exist" do
    expect(revise("A new outcome", "nope")).not_to include("EpicRevised")
  end

  it "refuses a complete epic", :aggregate_failures do
    cli("work.finish!", "to=m1", "no_change.value=a verify")

    expect(revise("A new outcome")).to include("a complete epic is not revised")
    expect(plain(row.outcome)).to eq("It is carried out")
  end
end
