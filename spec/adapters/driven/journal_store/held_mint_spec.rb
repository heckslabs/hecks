require "hecks"
require_relative "../../../../lib/hecks/hecks/adapters/journal_store"

# The Hecks domain's held mint. Each example injects the facts the decision reads and the minter,
# so the mint transaction is never reached and no database is needed.
module HeldMintSupport
  HeldMint = Hecks::Adapters::JournalStore::HeldMint

  # Facts of a domain whose shape moved from `from` to `to` at watermark 7, with era 3 next.
  def facts(from: "a1", to: "b2", verdict: "would_mint", reason: nil)
    decision = Struct.new(:verdict, :reason).new(verdict, reason)
    { held: 2, next_era: 3, watermark: 7, from: from, to: to, verdict: decision }
  end

  # A minter that records each call as `[era, request]` and answers `[label, ran]`.
  def recording_minter(label: "c3", ran: true)
    calls = []
    minter = lambda do |era, request|
      calls << [era, request]
      [label, ran]
    end
    [minter, calls]
  end

  def held_mint(facts, minter = nil)
    HeldMint.new(directory: "unused", reader: ->(_dir) { facts }, minter: minter&.first)
  end

  def answer_with(facts, run: "push-1", **)
    minter, calls = recording_minter
    [held_mint(facts, [minter, calls]).answer(run: run, **), calls]
  end
end

RSpec.describe "MintHeld, the Hecks domain's held mint" do
  include HeldMintSupport

  it "mints the next era only on would_mint at the watermark the caller read", :aggregate_failures do
    answer, calls = answer_with(facts, confirm: true, watermark: 7, rehearsal_verdict: "would_mint")
    expect([answer[:outcome], calls.map(&:first)]).to eq([{ value: "minted" }, [3]])
  end

  it "refuses by name when the watermark moved since the rehearsal" do
    expect { answer_with(facts, confirm: true, watermark: 6) }
      .to raise_error(Hecks::Runtime::WiringError, /moved from 6 to 7/)
  end

  it "refuses an unconfirmed mint and mints nothing" do
    expect { answer_with(facts) }.to raise_error(Hecks::Runtime::WiringError, /needs --confirm/)
  end

  it "answers no_change for a shape that did not move and mints nothing", :aggregate_failures do
    answer, calls = answer_with(facts(to: "a1"), confirm: true)
    expect([answer[:outcome], calls]).to eq([{ value: "no_change" }, []])
  end

  it "refuses a decision that is not would_mint, naming it" do
    undecided = facts(verdict: "needs_edge", reason: :unrecorded)
    expect { answer_with(undecided, confirm: true) }
      .to raise_error(Hecks::Runtime::WiringError, /needs_edge, not would_mint/)
  end

  it "refuses when the rehearsal said anything but would_mint" do
    expect { answer_with(facts, confirm: true, rehearsal_verdict: "would_refuse") }
      .to raise_error(Hecks::Runtime::WiringError, /would_refuse, not would_mint/)
  end

  it "faults the boarding when the decision refuses, and mints nothing", :aggregate_failures do
    refused = facts(to: "b2", verdict: "refused", reason: :audit)
    expect { answer_with(refused, confirm: true) }
      .to raise_error(Hecks::Runtime::WiringError, /the decision is refused/)
  end

  it "refuses a mint whose minter reports it did not run" do
    minter, calls = recording_minter(label: "the ledger already holds the current shape", ran: false)
    expect { held_mint(facts, [minter, calls]).answer(run: "push-2", confirm: true) }
      .to raise_error(Hecks::Runtime::WiringError, /already holds the current shape/)
  end
end
