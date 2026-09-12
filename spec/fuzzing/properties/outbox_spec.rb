require "spec_helper"
require "hecks/fuzzing"

# `Hecks::Fuzzing::Properties.outbox_rows_match_reactions` — the
# transactional outbox's own contract (`Runtime::Outbox`), held to a
# replay's own `history[:outbox_traces]` (`Replay#call`'s own before/
# after capture around each step's dispatch). See `lib/hecks/fuzzing/
# properties/outbox.rb`'s own header for the two checks this makes and
# why a `saga:` row gets only the weaker one — that asymmetry is not
# hypothetical: the first version of this property claimed the STRONGER
# check for sagas too, and it was live-caught false-positiving on
# `examples/banking`'s own `Onboarding` saga before this file existed
# (see "passes a real replay" below, which pins the exact scenario).
RSpec.describe "Hecks::Fuzzing::Properties.outbox_rows_match_reactions" do
  OUTBOX_SPEC_ROOT    = InMemoryDomain::ROOT
  OUTBOX_SPEC_BANKING = File.join(OUTBOX_SPEC_ROOT, "examples/banking")

  def unique_reference
    "OUTBOX-#{rand(1_000_000_000)}"
  end

  # A minimal duck-typed stand-in for `Bluebook::Behaviour::Policy` —
  # never the real DSL-built class, which needs a whole domain boot to
  # construct. The property reads exactly three things off a policy:
  # `#name` (to resolve the row's own consumer back to a declaration),
  # `#where` (the raw canonical string `Bluebook::Expression::Evaluator.
  # call` parses directly — see `properties/outbox.rb`'s own comment on
  # why `call`, not `call_rule`, is what lets a fake this simple work at
  # all), and `#fans_out?`.
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

  # THE REAL SCENARIO THIS PROPERTY'S OWN FIRST VERSION GOT WRONG.
  # `Onboarding`'s `ends_on Account::AccountOpened` (new_customer_
  # onboarding.bluebook) means `Outbox::Fanout.sagas`' own `listens?`
  # enqueues a `saga:Banking::Onboarding` row on EVERY `AccountOpened`,
  # including one this replay's own steps produce by opening an account
  # DIRECTLY — bypassing the onboarding case whose correlation would
  # actually have a live instance. `SagaInterpreter#end_saga` finds
  # nothing under that correlation to delete and logs NOTHING at all
  # (saga_interpreter.rb's own `return false unless ...delete(...)`) —
  # a `delivered` row with zero matching `saga_log` entries, produced by
  # perfectly ordinary operation, not a bug. This is a REAL replay
  # against `examples/banking` (no doctoring), and the property must
  # still answer `true`.
  it "passes a real replay whose saga row drains with no matching saga_log entry, and whose policy row drains " \
     "with a matching (if refused) reaction_log entry" do
    reference = unique_reference
    number    = unique_reference

    steps = [
      { "verb" => "Banking::Customer.Register",
        "args" => { "reference" => { "value" => reference },
                    "name"      => { "given" => "Ada", "family" => "Lovelace" },
                    "email"     => { "address" => "ada@example.com" } } },
      { "verb" => "Banking::Account.Open",
        "args" => { "number" => { "value" => number }, "kind" => { "name" => "current" },
                    "daily_limit" => { "cents" => 50_000 }, "customer" => reference } },
      { "verb" => "Banking::Account.CloseAccount", "args" => { "number" => { "value" => number } } }
    ]

    history = Hecks::Fuzzing::Replay.call(OUTBOX_SPEC_BANKING, steps)
    expect(history[:refusals]).to eq([])

    # Pin the fixture itself, not just the property's own verdict — if a
    # future change to Banking's own bluebooks makes CloseAccount stop
    # enqueueing a saga row for Onboarding, this test would otherwise
    # keep passing for a reason that no longer has anything to do with
    # what it claims to prove.
    saga_rows = history[:outbox_traces].flat_map { |t| t[:rows] }.select { |r| r[:consumer].start_with?("saga:") }
    expect(saga_rows).not_to be_empty
    expect(saga_rows.map { |r| r[:status] }.uniq).to eq(["delivered"])

    expect(Hecks::Fuzzing::Properties.outbox_rows_match_reactions(history)).to be(true)
  end

  describe "each check, seen failing (and the exemptions that keep it from over-firing)" do
    it "names a row that never drained inline" do
      %w[pending claimed].each do |status|
        history = { bluebooks: {}, outbox_traces: [outbox_trace(rows: outbox_row(consumer: "policy:Fake::Flag",
                                                                                 status:   status))] }

        result = Hecks::Fuzzing::Properties.outbox_rows_match_reactions(history)
        expect(result).to be_a(String)
        expect(result).to include("never drained inline").and include(status)
      end
    end

    it "names a row that failed to deliver" do
      history = { bluebooks:     {},
                  outbox_traces: [outbox_trace(rows: outbox_row(consumer: "saga:Fake::Flow", status: "failed",
                                                                error: "Hecks::Runtime::WiringError: no such saga"))] }

      result = Hecks::Fuzzing::Properties.outbox_rows_match_reactions(history)
      expect(result).to be_a(String)
      expect(result).to include("failed to deliver").and include("WiringError")
    end

    it "names a delivered policy row with no matching reaction_log entry and an unconditional (empty) where" do
      policy = OutboxSpecFakePolicy.new("Flag", "")
      history = { bluebooks:     { "Fake" => OutboxSpecFakeBluebook.new([policy]) },
                  outbox_traces: [outbox_trace(rows: outbox_row(consumer: "policy:Fake::Flag", status: "delivered",
                                                                event_name: "SomethingHappened"))] }

      result = Hecks::Fuzzing::Properties.outbox_rows_match_reactions(history)
      expect(result).to be_a(String)
      expect(result).to include("policy:Fake::Flag").and include("no matching reaction_log entry")
    end

    it "names a delivered policy row whose own where clause independently re-evaluates true, with no reaction logged" do
      policy = OutboxSpecFakePolicy.new("Flag", "amount == 5")
      row = outbox_row(consumer: "policy:Fake::Flag", status: "delivered", payload: { amount: 5 })
      history = { bluebooks:     { "Fake" => OutboxSpecFakeBluebook.new([policy]) },
                  outbox_traces: [outbox_trace(rows: row)] }

      result = Hecks::Fuzzing::Properties.outbox_rows_match_reactions(history)
      expect(result).to be_a(String)
      expect(result).to include("where clause independently re-evaluates true")
    end

    it "passes a delivered policy row whose own where clause independently re-evaluates false" do
      policy = OutboxSpecFakePolicy.new("Flag", "amount == 5")
      row = outbox_row(consumer: "policy:Fake::Flag", status: "delivered", payload: { amount: 6 })
      history = { bluebooks:     { "Fake" => OutboxSpecFakeBluebook.new([policy]) },
                  outbox_traces: [outbox_trace(rows: row)] }

      expect(Hecks::Fuzzing::Properties.outbox_rows_match_reactions(history)).to be(true)
    end

    it "passes a delivered policy row that DOES have a matching reaction_log entry, refused or not" do
      policy = OutboxSpecFakePolicy.new("Flag", "")
      row = outbox_row(consumer: "policy:Fake::Flag", status: "delivered")
      history = { bluebooks:     { "Fake" => OutboxSpecFakeBluebook.new([policy]) },
                  outbox_traces: [outbox_trace(rows:      row,
                                               reactions: [{ policy: "Flag", on: "SomethingHappened",
                                                             delivered: false, reason: "a made up refusal" }])] }

      expect(Hecks::Fuzzing::Properties.outbox_rows_match_reactions(history)).to be(true)
    end

    it "does not flag a delivered for_each policy row with no matching reaction — fan-out row count is " \
       "fanout_dispatches_once_per_matching_row's own job, not this one's" do
      fans_out_policy = OutboxSpecFakePolicy.new("FreezeAccountsOnSuspension", "")
      def fans_out_policy.fans_out? = true

      row = outbox_row(consumer: "policy:Banking::FreezeAccountsOnSuspension", status: "delivered")
      history = { bluebooks:     { "Banking" => OutboxSpecFakeBluebook.new([fans_out_policy]) },
                  outbox_traces: [outbox_trace(rows: row)] } # no matching reaction — where held but 0 rows matched

      expect(Hecks::Fuzzing::Properties.outbox_rows_match_reactions(history)).to be(true)
    end

    it "does not flag a delivered saga row with no matching saga_log entry — Fanout.sagas' own listens? gives " \
       "no such guarantee (see this spec's own real-replay case above)" do
      row = outbox_row(consumer: "saga:Fake::Flow", status: "delivered")
      history = { bluebooks: {}, outbox_traces: [outbox_trace(rows: row)] } # no matching saga_log entry

      expect(Hecks::Fuzzing::Properties.outbox_rows_match_reactions(history)).to be(true)
    end

    it "is inconclusive, not a claimed mismatch, when the row names a policy nothing declares" do
      row = outbox_row(consumer: "policy:Fake::Ghost", status: "delivered")
      history = { bluebooks: { "Fake" => OutboxSpecFakeBluebook.new([]) }, outbox_traces: [outbox_trace(rows: row)] }

      expect(Hecks::Fuzzing::Properties.outbox_rows_match_reactions(history)).to be(true)
    end

    it "passes an empty history outright" do
      expect(Hecks::Fuzzing::Properties.outbox_rows_match_reactions({ bluebooks: {}, outbox_traces: [] })).to be(true)
    end
  end
end
