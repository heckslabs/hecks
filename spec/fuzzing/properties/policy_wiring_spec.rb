require "spec_helper"
require "hecks/fuzzing"

# `Properties.policy_reactions_follow_declared_wiring`. The failing cases doctor a history built
# from the real banking bluebooks, since a runtime that fires a policy off its declaration is
# exactly what the property exists to catch and cannot be provoked on demand.
RSpec.describe "Hecks::Fuzzing::Properties.policy_reactions_follow_declared_wiring", :aggregate_failures do
  def banking_path = File.join(InMemoryDomain::ROOT, "examples/banking")

  def bluebooks = @bluebooks ||= Hecks::Fuzzing::Replay.call(banking_path, [])[:bluebooks]

  def verdict(history) = Hecks::Fuzzing::Properties.policy_reactions_follow_declared_wiring(history)

  # The declared `across` policy these cases read: it names an event, a qualifier and a target domain.
  def freeze_policy
    bluebooks.each_value.lazy.flat_map(&:policies).find { |policy| policy.name == "ReviewOnFreeze" }
  end

  def freeze_trigger = "#{freeze_policy.target_domain}::#{freeze_policy.trigger_command}"

  def frozen_event = { name: freeze_policy.event_name, aggregate: "Banking::Account", id: "acct-1" }

  def reaction(**overrides)
    { policy: "ReviewOnFreeze", on: freeze_policy.event_name, trigger: freeze_trigger, delivered: false }.merge(overrides)
  end

  def history(reactions, events: [frozen_event])
    { bluebooks: bluebooks, events: events, reactions: reactions }
  end

  it "passes a history with no reactions" do
    expect(verdict(history([], events: []))).to be(true)
  end

  it "passes a reaction that is the one its policy declares, for an event that happened" do
    expect(verdict(history([reaction]))).to be(true)
  end

  it "names a reaction logged for an event the policy does not answer" do
    result = verdict(history([reaction(on: "SomethingElse")]))

    expect(result).to be_a(String).and include("ReviewOnFreeze", "SomethingElse", freeze_policy.event_name)
  end

  it "names a reaction that triggered somewhere other than the declared target" do
    result = verdict(history([reaction(trigger: "Elsewhere::Nope.Go")]))

    expect(result).to be_a(String).and include("Elsewhere::Nope.Go", freeze_trigger)
  end

  it "names a reaction for a policy no loaded bluebook declares" do
    result = verdict(history([reaction(policy: "NoSuchPolicy")]))

    expect(result).to be_a(String).and include("NoSuchPolicy", "no loaded bluebook declares")
  end

  it "names a reaction to an event that was never emitted in this history" do
    result = verdict(history([reaction], events: []))

    expect(result).to be_a(String).and include("no such event was emitted")
  end

  it "names a reaction whose only matching event came from an aggregate the policy's qualifier excludes" do
    wrong_aggregate = frozen_event.merge(aggregate: "Banking::Customer")

    expect(verdict(history([reaction], events: [wrong_aggregate]))).to be_a(String).and include("no such event")
  end

  it "reports each offending reaction once, however often it repeats" do
    result = verdict(history([reaction(on: "SomethingElse"), reaction(on: "SomethingElse")]))

    expect(result.scan("SomethingElse").size).to be < 4
    expect(result.split("; ").size).to eq(1)
  end

  # Not hand-built: a closed account makes NotifyOnClosure fire at a domain nothing loaded.
  it "passes the reactions a real banking replay logs, including an undelivered cross-domain one" do
    number = "WIRE-#{rand(1_000_000_000)}"
    reference = "WIRE-C-#{rand(1_000_000_000)}"
    steps = [
      { "verb" => "Banking::Customer.Register",
        "args" => { "reference" => { "value" => reference },
                    "name" => { "given" => "Ada", "family" => "Lovelace" },
                    "email" => { "address" => "ada@example.com" } } },
      { "verb" => "Banking::Account.Open",
        "args" => { "number" => { "value" => number }, "kind" => { "name" => "current" },
                    "daily_limit" => { "cents" => 50_000 }, "customer" => reference } },
      { "verb" => "Banking::Account.CloseAccount", "args" => { "number" => { "value" => number } } }
    ]

    replayed = Hecks::Fuzzing::Replay.call(banking_path, steps)

    expect(replayed[:refusals]).to eq([])
    expect(replayed[:reactions]).not_to be_empty
    expect(verdict(replayed)).to be(true)
  end
end
