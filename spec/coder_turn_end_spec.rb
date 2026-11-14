require "spec_helper"
require "hecks/hecks/adapters/turn_facts"

# A coder's turn ends done only after its branch landed or was submitted. `Turn.End` asks the
# TurnFacts port, here a stand-in that answers the facts each example names, and the Coder bluebook
# holds a coder that still holds its started Work item, asks nothing and has landed nothing. Each
# fact that lets a turn end is shown alone.
RSpec.describe "a coder's turn ending" do
  let(:hecks) { boot_hecks_in_memory }

  # What the port measures of a coder that said done and handed nothing in.
  BARE = { role: "coder", held: true, landed: false, reviewing: false, again: false, question: "", word: "done" }.freeze

  def measuring(**facts)
    port = instance_double(Hecks::Adapters::TurnFacts, measure_turn: BARE.merge(facts))
    allow(Hecks::Adapters::TurnFacts).to receive(:new).and_return(port)
  end

  def end_turn(**facts)
    measuring(**facts)
    argv = ["coder", "Turn.end!", "run.value=t-1", "again.value=#{facts.fetch(:again, false)}", "--wait"]
    Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, argv: argv, program: "hecks")
  end

  def reason(**facts) = end_turn(**facts).last.to_s

  def events(**facts) = JSON.parse(end_turn(**facts).first).fetch("events")

  it "holds a coder's turn that ends done with nothing landed or submitted", :aggregate_failures do
    _text, status, why = end_turn

    expect(status).to eq(1)
    expect(why).to include('failure state "held"')
  end

  it "tells the held coder to submit" do
    expect(reason).to include("exe/hecks coder Submission.submit!")
  end

  it "tells the held coder how to ask or hand the item back", :aggregate_failures do
    expect(reason).to include("[owner]")
    expect(reason).to include("Work.yield!")
  end

  it "ends a turn whose Work item is no longer started, as after a submission or a yield" do
    expect(events(held: false)).to include("TurnEnded")
  end

  it "ends a turn whose branch landed" do
    expect(events(landed: true)).to include("TurnEnded")
  end

  it "ends a turn that waits on a plan review" do
    expect(events(reviewing: true)).to include("TurnEnded")
  end

  %w[[review] [confirm] [retry] [choose] [owner]].each do |marker|
    it "ends a turn whose closing message asks a #{marker} question" do
      expect(events(question: "#{marker} may I go on?")).to include("TurnEnded")
    end
  end

  it "holds a turn whose bracketed line is not one of the five markers" do
    expect(events(question: "[note] all done")).to include("TurnHeld")
  end

  %w[blocked submitted].each do |word|
    it "ends a turn whose last word is #{word}" do
      expect(events(word: word)).to include("TurnEnded")
    end
  end

  it "ends the turn of a run that is not a coder's" do
    expect(events(role: "architect")).to include("TurnEnded")
  end

  it "ends a turn that ends again after it was held" do
    expect(events(again: true)).to include("TurnEnded")
  end

  it "ends a turn the port cannot measure" do
    port = instance_double(Hecks::Adapters::TurnFacts)
    allow(port).to receive(:measure_turn).and_raise(Hecks::Adapters::ConsoleCapture::Failure, "no started run is named t-1")
    allow(Hecks::Adapters::TurnFacts).to receive(:new).and_return(port)
    argv = ["coder", "Turn.end!", "run.value=t-1", "--wait"]

    expect(Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, argv: argv, program: "hecks").first).to include("TurnEnded")
  end
end
