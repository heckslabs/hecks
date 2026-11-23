require "spec_helper"
require "hecks/clients/transcript/turns"

RSpec.describe Hecks::Clients::Transcript do
  it "reads a turn as speaker, time and words, joining its lines", :aggregate_failures do
    turns = described_class.turns("[Rosa] 09:00:05\nHello there\nand welcome.\n")
    expect(turns).to eq([{ speaker: "Rosa", at: "09:00:05", text: "Hello there and welcome." }])
  end

  it "keeps words that come before any speaker as a turn with none" do
    expect(described_class.turns("tail of a turn\n")).to eq([{ speaker: nil, at: nil, text: "tail of a turn" }])
  end
end
