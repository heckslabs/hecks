require "spec_helper"
require "hecks/fuzzing"

# `Properties.outbox_rows_match_reactions` holds `history[:outbox_traces]` to the outbox contract;
# a `saga:` row gets only the weaker check (see the real-replay example below).
RSpec.describe "Hecks::Fuzzing::Properties.outbox_rows_match_reactions", :aggregate_failures do
  OUTBOX_SPEC_ROOT    = InMemoryDomain::ROOT
  OUTBOX_SPEC_BANKING = File.join(OUTBOX_SPEC_ROOT, "examples/banking")

  def unique_reference
    "OUTBOX-#{rand(1_000_000_000)}"
  end

  # Duck-typed stand-in for a policy: the property reads only #name, #where (parsed by
  # `Evaluator.call`) and #fans_out?.
  OutboxSpecFakePolicy = Struct.new(:name, :where) do
    def fans_out? = false
  end
  OutboxSpecFakeBluebook = Struct.new(:policies)

  def outbox_row(consumer:, status:, event_name: "SomethingHappened", payload: {}, error: nil)
    { delivery_id: "d1/#{consumer}", event_uid: "d1", aggregate: "thing", domain: "Fake",
      kind: "reaction", consumer: consumer,
      event: { name: event_name, aggregate: "Fake::Thing", id: "t1", payload: payload, occurred_at: nil,
                correlation: nil },
      status: status, attempts: 1, error: error }
  end

  def outbox_trace(rows:, reactions: [], sagas: [])
    { verb: "Fake::Thing.Do", rows: rows.is_a?(Array) ? rows : [rows], reactions: reactions, sagas: sagas }
  end

  def outbox_history(row, bluebooks: {}, reactions: [])
    { bluebooks: bluebooks, outbox_traces: [outbox_trace(rows: row, reactions: reactions)] }
  end

  def fake_bluebooks(domain, *policies) = { domain => OutboxSpecFakeBluebook.new(policies) }

  def finding(history) = Hecks::Fuzzing::Properties.outbox_rows_match_reactions(history)

  def banking_saga_steps(reference, number)
    [
      { "verb" => "Banking::Customer.Register",
        "args" => { "reference" => { "value" => reference },
                    "name"      => { "given" => "Ada", "family" => "Lovelace" },
                    "email"     => { "address" => "ada@example.com" } } },
      { "verb" => "Banking::Account.Open",
        "args" => { "number" => { "value" => number }, "kind" => { "name" => "current" },
                    "daily_limit" => { "cents" => 50_000 }, "customer" => reference } },
      { "verb" => "Banking::Account.CloseAccount", "args" => { "number" => { "value" => number } } }
    ]
  end

  # Regression: Onboarding's `ends_on AccountOpened` enqueues a saga row on every AccountOpened,
  # even with no live instance; `end_saga` then logs nothing, so a delivered saga row can
  # legitimately have no saga_log entry. Real replay, no doctoring; must answer true.
  context "with a real replay whose saga row drains with no matching saga_log entry, and whose " \
          "policy row drains with a matching (if refused) reaction_log entry" do
    before do
      @history = Hecks::Fuzzing::Replay.call(OUTBOX_SPEC_BANKING, banking_saga_steps(unique_reference, unique_reference))
      rows = @history[:outbox_traces].flat_map { |t| t[:rows] }
      @saga_rows = rows.select { |r| r[:consumer].start_with?("saga:") }
    end

    it "refuses no step" do
      expect(@history[:refusals]).to eq([])
    end

    # Pins the fixture: if CloseAccount stops enqueueing a saga row, the next example would pass vacuously.
    it "enqueues a saga row, and it drains" do
      expect(@saga_rows).not_to be_empty
      expect(@saga_rows.map { |r| r[:status] }.uniq).to eq(["delivered"])
    end

    it "passes" do
      expect(finding(@history)).to be(true)
    end
  end

  describe "each check, seen failing (and the exemptions that keep it from over-firing)" do
    it "names a row that never drained inline" do
      %w[pending claimed].each do |status|
        result = finding(outbox_history(outbox_row(consumer: "policy:Fake::Flag", status: status)))

        expect(result).to be_a(String).and include("never drained inline", status)
      end
    end

    it "names a row that failed to deliver" do
      row = outbox_row(consumer: "saga:Fake::Flow", status: "failed", error: "Hecks::Runtime::WiringError: no such saga")
      result = finding(outbox_history(row))

      expect(result).to be_a(String).and include("failed to deliver", "WiringError")
    end

    it "names a delivered policy row with no matching reaction_log entry and an unconditional (empty) where" do
      row = outbox_row(consumer: "policy:Fake::Flag", status: "delivered", event_name: "SomethingHappened")
      result = finding(outbox_history(row, bluebooks: fake_bluebooks("Fake", OutboxSpecFakePolicy.new("Flag", ""))))

      expect(result).to be_a(String).and include("policy:Fake::Flag", "no matching reaction_log entry")
    end

    it "names a delivered policy row whose own where clause independently re-evaluates true, with no reaction logged" do
      policy = OutboxSpecFakePolicy.new("Flag", "amount == 5")
      row = outbox_row(consumer: "policy:Fake::Flag", status: "delivered", payload: { amount: 5 })
      result = finding(outbox_history(row, bluebooks: fake_bluebooks("Fake", policy)))

      expect(result).to be_a(String).and include("where clause independently re-evaluates true")
    end

    it "passes a delivered policy row whose own where clause independently re-evaluates false" do
      policy = OutboxSpecFakePolicy.new("Flag", "amount == 5")
      row = outbox_row(consumer: "policy:Fake::Flag", status: "delivered", payload: { amount: 6 })

      expect(finding(outbox_history(row, bluebooks: fake_bluebooks("Fake", policy)))).to be(true)
    end

    it "passes a delivered policy row that DOES have a matching reaction_log entry, refused or not" do
      policy = OutboxSpecFakePolicy.new("Flag", "")
      row = outbox_row(consumer: "policy:Fake::Flag", status: "delivered")
      reaction = { policy: "Flag", on: "SomethingHappened", delivered: false, reason: "a made up refusal" }
      history = outbox_history(row, bluebooks: fake_bluebooks("Fake", policy), reactions: [reaction])

      expect(finding(history)).to be(true)
    end

    it "does not flag a delivered for_each policy row with no matching reaction — fan-out row count is " \
       "fanout_dispatches_once_per_matching_row's own job, not this one's" do
      fans_out_policy = OutboxSpecFakePolicy.new("FreezeAccountsOnSuspension", "")
      def fans_out_policy.fans_out? = true

      row = outbox_row(consumer: "policy:Banking::FreezeAccountsOnSuspension", status: "delivered")
      # no matching reaction — where held but 0 rows matched
      history = outbox_history(row, bluebooks: fake_bluebooks("Banking", fans_out_policy))

      expect(finding(history)).to be(true)
    end

    it "does not flag a delivered saga row with no matching saga_log entry — Fanout.sagas' own listens? gives " \
       "no such guarantee (see this spec's own real-replay case above)" do
      row = outbox_row(consumer: "saga:Fake::Flow", status: "delivered")
      # no matching saga_log entry

      expect(finding(outbox_history(row))).to be(true)
    end

    it "is inconclusive, not a claimed mismatch, when the row names a policy nothing declares" do
      row = outbox_row(consumer: "policy:Fake::Ghost", status: "delivered")

      expect(finding(outbox_history(row, bluebooks: fake_bluebooks("Fake")))).to be(true)
    end

    it "passes an empty history outright" do
      expect(finding({ bluebooks: {}, outbox_traces: [] })).to be(true)
    end
  end
end
