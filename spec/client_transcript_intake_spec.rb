require "spec_helper"
require "hecks/clients/transcript/intake"

# Reads the made-up bakery client's transcript, pasted in pieces, into the interview.
module TranscriptIntakeSteps
  FIXTURES = File.expand_path("fixtures/clients/bakery", __dir__)

  # @param name [String] a fixture file name
  # @return [String] the pasted text
  def chunk(name)
    File.read(File.join(FIXTURES, name))
  end

  # @param hecks [Object] the booted Interviews runtime
  # @return [#call] a dispatch that keeps each call it makes and runs it
  def recording(hecks, calls)
    lambda do |name, **attrs|
      calls << attrs
      hecks.dispatch_flat(name, **attrs)
    end
  end

  # @param hecks [Object] the booted Interviews runtime
  # @return [Hash] the bakery interview's stored state, as plain data
  def interview(hecks)
    aggregate = hecks.registry.bluebook("Interviews").aggregate("Interview")
    Hecks::Runtime::Value.materialize(hecks.registry.repository("Interviews", aggregate).find("BAKERY-1").state)
  end
end

RSpec.describe Hecks::Clients::Transcript::Intake do
  include TranscriptIntakeSteps

  let(:hecks) { Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/interviews"), install_driving: false) }
  let(:calls) { [] }
  let(:intake) do
    described_class.new(dispatch: recording(hecks, calls), reference: "BAKERY-1", subject: "How orders reach the bakery")
  end
  let(:exchanges) { interview(hecks)[:exchanges] }

  def paste_all
    intake.paste(chunk("transcript_1.txt"))
    intake.paste(chunk("transcript_2.txt"))
    intake.finish
  end

  it "records one exchange per turn, in order, the cut turn as one" do
    paste_all
    expect(exchanges.map { |e| e[:speaker] }).to eq(%w[Rosa Marta Rosa Marta Rosa Marta])
  end

  it "joins a turn split across two chunks" do
    paste_all
    expect(exchanges[3][:answer]).to eq("We bake the wedding cakes a day ahead and the rest " \
                                        "goes in the ovens before the shop opens at seven.")
  end

  it "adds nothing when a chunk is pasted again", :aggregate_failures do
    paste_all
    intake.paste(chunk("transcript_2.txt"))
    intake.finish
    expect(exchanges.size).to eq(6)
  end

  it "skips a turn repeated at the start of the next chunk" do
    intake.paste(chunk("transcript_1.txt"))
    intake.paste("[Marta] 09:01:02\nWe bake the wedding cakes a day ahead and the rest goes in the ovens.\n")
    intake.finish
    expect(exchanges.size).to eq(4)
  end

  it "holds the last turn back until the next chunk or finish", :aggregate_failures do
    expect(intake.paste(chunk("transcript_1.txt"))).to eq(3)
    expect(intake.finish).to eq(1)
  end

  it "opens the interview with its subject, kept local, and no later turn repeats them", :aggregate_failures do
    paste_all
    expect(interview(hecks)).to include(keeping: { value: "local" }).or include(keeping: "local")
    expect(calls.map { |c| c.key?(:subject) }).to eq([true] + [false] * 5)
  end

  it "records nothing for a blank chunk or a turn with no words", :aggregate_failures do
    expect(intake.paste("  \n\n")).to eq(0)
    expect(intake.paste("[Rosa] 09:05:00\n\n")).to eq(0)
    expect(intake.finish).to eq(0)
  end

  it "finishes once and refuses a paste after it", :aggregate_failures do
    paste_all
    expect(intake.finish).to eq(0)
    expect { intake.paste("[Rosa] 09:09:09\nHello\n") }.to raise_error(described_class::Finished)
  end
end

RSpec.describe Hecks::Clients::Transcript do
  it "reads a turn as speaker, time and words, joining its lines", :aggregate_failures do
    turns = described_class.turns("[Rosa] 09:00:05\nHello there\nand welcome.\n")
    expect(turns).to eq([{ speaker: "Rosa", at: "09:00:05", text: "Hello there and welcome." }])
  end

  it "keeps words that come before any speaker as a turn with none" do
    expect(described_class.turns("tail of a turn\n")).to eq([{ speaker: nil, at: nil, text: "tail of a turn" }])
  end
end
