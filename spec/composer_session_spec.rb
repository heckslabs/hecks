require "spec_helper"
require "hecks/composer"
require "hecks/composer/session"

# The session keeps one draft per workspace file, so the page can show what each file held and
# when, newest revision first.
RSpec.describe Hecks::Composer::Session do
  let(:session) { described_class.new }

  def texts(path) = session.timeline(path).map { |entry| entry[:text] }

  it "shows both revisions of a file, newest first", :aggregate_failures do
    session.record(path: "a.bluebook", text: %(Hecks.bluebook "Ledger" do\nend\n))
    session.record(path: "a.bluebook", text: %(Hecks.bluebook "Ledger" do\n  vision "x"\nend\n))

    expect(texts("a.bluebook").size).to eq(2)
    expect(texts("a.bluebook").first).to include("vision")
  end

  it "names each entry and dates it", :aggregate_failures do
    session.record(path: "a.bluebook", text: "one")
    session.record(path: "a.bluebook", text: "two")

    expect(session.timeline("a.bluebook").map { |entry| entry[:name] }).to eq(%w[DraftRevised DraftBegun])
    expect(session.timeline("a.bluebook").first[:at]).not_to be_nil
  end

  it "keeps separate timelines for separate paths", :aggregate_failures do
    session.record(path: "a.bluebook", text: "one")
    session.record(path: "b.bluebook", text: "other")

    expect(texts("a.bluebook")).to eq(["one"])
    expect(texts("b.bluebook")).to eq(["other"])
  end

  it "gives an unknown path an empty timeline" do
    expect(session.timeline("never.bluebook")).to eq([])
  end

  it "takes the bluebook's name from the text" do
    session.record(path: "a.bluebook", text: %(Hecks.bluebook "Ledger" do\nend\n))

    expect(Hecks::Composer::Plain.call(session.draft("a.bluebook")[:bluebook_name])).to eq("Ledger")
  end
end
