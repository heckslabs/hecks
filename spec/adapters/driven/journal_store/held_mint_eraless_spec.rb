require "hecks"
require_relative "../../../../lib/hecks/hecks/adapters/journal_store"

# The held mint for a Hecks domain in Memory (the default): it holds no eras, so the mint passes
# straight through.
RSpec.describe "the held mint of a domain in Memory" do
  let(:held_mint_class) { Hecks::Adapters::JournalStore::HeldMint }
  let(:calls) { [] }
  let(:held) do
    held_mint_class.new(directory: "unused", reader: ->(_dir) { { eraless: "Memory" } },
                        minter: ->(*call) { calls << call })
  end

  it "passes through, minting nothing", :aggregate_failures do
    answer = held.answer(run: "push-1", confirm: true)
    expect(answer[:outcome]).to eq({ value: "eraless" })
    expect(calls).to be_empty
  end

  it "reads the committed Hecks domain, which boots in Memory, as eraless" do
    expect(held_mint_class.read(held_mint_class::DOMAIN)).to eq({ eraless: "Memory" })
  end
end
