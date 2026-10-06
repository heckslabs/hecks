require "spec_helper"
require "hecks/fuzzing"

# `Properties.references_resolve_to_earlier_records`. A real replay passes it; a dangling
# reference cannot be dispatched (the pipeline refuses it with NotFound), so the failing cases
# strip the creating event out of an otherwise-real history.
RSpec.describe "Hecks::Fuzzing::Properties.references_resolve_to_earlier_records", :aggregate_failures do
  def banking_path = File.join(InMemoryDomain::ROOT, "examples/banking")

  def verdict(history) = Hecks::Fuzzing::Properties.references_resolve_to_earlier_records(history)

  def funded_account_history
    number = "REF-#{rand(1_000_000_000)}"
    reference = "REF-C-#{rand(1_000_000_000)}"
    steps = [
      { "verb" => "Banking::Customer.Register",
        "args" => { "reference" => { "value" => reference },
                    "name" => { "given" => "Ada", "family" => "Lovelace" },
                    "email" => { "address" => "ada@example.com" } } },
      { "verb" => "Banking::Account.Open",
        "args" => { "number" => { "value" => number }, "kind" => { "name" => "current" },
                    "daily_limit" => { "cents" => 50_000 }, "customer" => reference } },
      { "verb" => "Banking::Account.Credit",
        "args" => { "number" => { "value" => number }, "amount" => { "cents" => 10_000, "currency" => "USD" },
                    "narrative" => { "text" => "Opening deposit" } } }
    ]
    history = Hecks::Fuzzing::Replay.call(banking_path, steps)
    expect(history[:refusals]).to eq([])
    history
  end

  it "passes an empty history" do
    expect(verdict(bluebooks: Hecks::Fuzzing::Replay.call(banking_path, [])[:bluebooks], events: [])).to be(true)
  end

  it "passes a real replay, where every referencing command addressed a record an earlier event created" do
    expect(verdict(funded_account_history)).to be(true)
  end

  it "names a referencing command accepted against a record whose creating event is missing" do
    history = funded_account_history
    account_events = history[:events].select { |event| event[:aggregate] == "Banking::Account" }
    creating = account_events.first
    doctored = history.merge(events: history[:events].reject { |event| event.equal?(creating) })

    result = verdict(doctored)

    expect(result).to be_a(String).and include("was accepted referencing", "Banking::Account#", "no earlier event")
  end

  it "does not count an event that came after the one being checked as having created the record" do
    history = funded_account_history
    account_events = history[:events].select { |event| event[:aggregate] == "Banking::Account" }
    creating = account_events.first
    reordered = history[:events].reject { |event| event.equal?(creating) } + [creating]

    expect(verdict(history.merge(events: reordered))).to be_a(String).and include("no earlier event")
  end
end
