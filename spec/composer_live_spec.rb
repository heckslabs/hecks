require "spec_helper"
require "hecks/composer"
require "hecks/composer/live"

# A live workspace holds one booted domain so a console can dispatch against it.
RSpec.describe Hecks::Composer::Live do
  let(:dir) { File.expand_path("fixtures/composer/account", __dir__) }

  after { @live&.close }

  def live = (@live ||= described_class.open(dir: dir))

  def open_account(number = "A1") = live.dispatch(verb: "Ledger::Account.Open", with: { "number" => { "value" => number } })

  def credit(cents, to: "A1")
    live.dispatch(verb: "Ledger::Account.Credit", to: to, with: { "amount" => { "cents" => cents, "currency" => "USD" } })
  end

  def entry(verb) = live.commands.find { |command| command[:verb] == verb }

  def open_broken
    text = %(Hecks.bluebook "Ledger" do\n  aggregate "Account" do\n)
    described_class.open(dir: dir, buffers: { "ledger.bluebook" => text })
  end

  def captured_stage
    stages = []
    allow(Hecks::Composer::Workspace).to receive(:materialize).and_wrap_original do |original, **args|
      original.call(**args).tap { |stage| stages << stage }
    end
    yield
    stages.first
  end

  it "names the bluebook and lists its aggregate commands by verb", :aggregate_failures do
    expect(live.chapter_name).to eq("Ledger")
    expect(live.commands.map { |command| command[:verb] }).to contain_exactly(
      "Ledger::Account.Open", "Ledger::Account.Credit", "Ledger::Account.FreezeAccount"
    )
  end

  it "marks the command that creates a record", :aggregate_failures do
    expect(entry("Ledger::Account.Open")).to include(creates: true, goal: "Open an account under a number")
    expect(entry("Ledger::Account.Credit")[:creates]).to be(false)
  end

  it "describes each argument", :aggregate_failures do
    args = entry("Ledger::Account.Credit")[:args]

    expect(args).to eq([{ name: "amount", type: "PositiveMoney", optional: false }])
  end

  it "starts a value object argument from its attributes' defaults", :aggregate_failures do
    expect(entry("Ledger::Account.Credit")[:template]).to eq("amount" => { "cents" => 0, "currency" => "USD" })
    expect(entry("Ledger::Account.Open")[:template]).to eq("number" => { "value" => "" })
  end

  it "dispatches a command and returns its events and the record", :aggregate_failures do
    result = open_account

    expect(result).to include(ok: true, events: ["AccountOpened"])
    expect(result[:instance]).to include(number: "A1")
  end

  it "applies a later command to the same record", :aggregate_failures do
    open_account
    result = credit(500)

    expect(result).to include(ok: true, events: ["AccountCredited"])
    expect(live.records["Account"].first[:balance]).to eq(cents: 500, currency: "USD")
  end

  it "refuses an amount that is not positive", :aggregate_failures do
    open_account
    result = credit(-5)

    expect(result).to include(ok: false, kind: "InvariantViolation")
    expect(result[:error]).to include("positive")
  end

  it "refuses a command for a record that does not exist", :aggregate_failures do
    result = credit(500, to: "nobody")

    expect(result[:ok]).to be(false)
    expect(result[:error]).to be_a(String)
  end

  it "lists no records before anything is dispatched" do
    expect(live.records).to eq("Account" => [])
  end

  it "keeps the events in the order they happened", :aggregate_failures do
    open_account
    credit(500)

    expect(live.history.map { |event| event[:name] }).to eq(%w[AccountOpened AccountCredited])
    expect(live.history(1).map { |event| event[:name] }).to eq(["AccountCredited"])
  end

  it "removes its stage on close, and closes twice without harm", :aggregate_failures do
    stage = captured_stage { live }

    expect(File.directory?(stage)).to be(true)
    live.close
    live.close
    expect(File.exist?(stage)).to be(false)
  end

  it "removes the stage and raises when the workspace will not boot", :aggregate_failures do
    stage = captured_stage { expect { open_broken }.to raise_error(ScriptError) }

    expect(stage).to be_a(String)
    expect(File.exist?(stage)).to be(false)
  end
end
