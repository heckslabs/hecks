
require "spec_helper"
require "hecksagain/fuzzing"

# Declared properties over generated histories — the other half of
# property-based testing the fuzzer was missing. Two directions, as
# usual: the standard battery HOLDS over real generated sequences
# (below), and each property actually FIRES against a hand-built
# history that violates it — a property nothing can ever fail is
# decoration, the same lesson the coverage gates state for
# declarations.
RSpec.describe "Hecksagain::Fuzzing::Properties" do
  ROOT_DIR = InMemoryDomain::ROOT
  PROPERTIES_PIZZAS  = File.join(ROOT_DIR, "examples/pizzas")
  PROPERTIES_BANKING = File.join(ROOT_DIR, "examples/banking")
  # S17's own fixture, now a real bootable domain (no .hecksagon at all
  # — Memory by construction) rather than the raw-Kernel.load-only
  # fixture it was — the only real corpus site anywhere using entity-
  # owned append/remove/multiply/clamp, item 9's own real target.
  PROPERTIES_ENTITY_MUTATIONS = File.join(ROOT_DIR, "spec/fixtures/entity_list_mutations")
  # The self-hosted META-domain — Expression + Translation, in that load
  # order — used ONLY to pin the multi-bluebook regression below. A real
  # `bin/fuzz` run against this domain (Expression loads first) is what
  # found it: every genuine `Translation::Map.Seal` refusal read as
  # unresolvable because `command_for_verb` only ever consulted whichever
  # bluebook happened to load first.
  PROPERTIES_GRAMMAR = File.join(ROOT_DIR, "lib/hecksagain/grammar")

  def generated_history(domain, seed)
    steps = Hecksagain::Fuzzing::SequenceGenerator.generate(domain, seed: seed, steps: 25)
    Hecksagain::Fuzzing::Replay.call(domain, steps)
  end

  describe "the standard battery, over real generated sequences" do
    [[PROPERTIES_PIZZAS, 5], [PROPERTIES_BANKING, 5], [PROPERTIES_ENTITY_MUTATIONS, 10]].each do |domain, seed_count|
      it "holds for #{File.basename(domain)} across #{seed_count} seeds" do
        (1..seed_count).each do |seed|
          history = generated_history(domain, seed)
          results = Hecksagain::Fuzzing::Properties.check(history)

          results.each do |property, result|
            expect(result).to eq(true), "#{domain} seed #{seed} — #{property}: #{result}"
          end
        end
      end

      it "stays deterministic for #{File.basename(domain)} across #{seed_count} seeds" do
        (1..seed_count).each do |seed|
          steps = Hecksagain::Fuzzing::SequenceGenerator.generate(domain, seed: seed, steps: 25)
          result = Hecksagain::Fuzzing::Properties.replay_is_deterministic(domain, steps)

          expect(result).to eq(true), "#{domain} seed #{seed}: #{result}"
        end
      end
    end
  end

  describe "each property, seen failing" do
    def bluebook_for(domain)
      Hecksagain::Fuzzing::Replay.call(domain, [])[:bluebook]
    end

    def bluebooks_for(domain)
      Hecksagain::Fuzzing::Replay.call(domain, [])[:bluebooks]
    end

    it "lifecycle_values_are_declared names an instance holding an undeclared state" do
      history = { bluebook: bluebook_for(PROPERTIES_PIZZAS),
                  instances: { "Pizzas::Order#p1" => { status: "teleported" } } }

      result = Hecksagain::Fuzzing::Properties.lifecycle_values_are_declared(history)
      expect(result).to be_a(String)
      expect(result).to include("teleported")
    end

    it "lifecycle_values_are_declared passes a genuinely declared state through" do
      history = { bluebook: bluebook_for(PROPERTIES_PIZZAS),
                  instances: { "Pizzas::Order#p1" => { status: "available" } } }

      expect(Hecksagain::Fuzzing::Properties.lifecycle_values_are_declared(history)).to eq(true)
    end

    it "saga_advances_follow_declared_handlers names an advance no handler declares" do
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  sagas: [{ process_manager: "Settlement", on: "Invented", instance: "x",
                            advanced: true, from: "requested", to: "nowhere_declared" }] }

      result = Hecksagain::Fuzzing::Properties.saga_advances_follow_declared_handlers(history)
      expect(result).to be_a(String)
      expect(result).to include("nowhere_declared")
    end

    it "saga_advances_follow_declared_handlers passes a genuinely declared edge through" do
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  sagas: [{ process_manager: "Settlement", on: "TransferRequested", instance: "x",
                            advanced: true, from: "requested", to: "requested" }] }

      expect(Hecksagain::Fuzzing::Properties.saga_advances_follow_declared_handlers(history)).to eq(true)
    end

    it "query_answers_match_reference names a native answer the reference interpreter disputes" do
      history = { queries: [{ query: "Pizzas::Order.Expensive", args: {},
                              rows: [{ id: "Margherita" }],
                              reference_rows: [] }] }

      result = Hecksagain::Fuzzing::Properties.query_answers_match_reference(history)
      expect(result).to be_a(String)
      expect(result).to include("Pizzas::Order.Expensive").and include("natively")
    end

    it "query_answers_match_reference passes agreement, refusals, and read-model asks through" do
      history = { queries: [
        { query: "Pizzas::Order.Expensive", args: {}, rows: [{ id: "M" }], reference_rows: [{ id: "M" }] },
        { query: "Pizzas::Order.Expensive", args: {}, error: "refused" },
        { query: "Pizzas.some_read_model", args: {}, rows: [], reference_rows: nil }
      ] }

      expect(Hecksagain::Fuzzing::Properties.query_answers_match_reference(history)).to eq(true)
    end

    it "replay_is_deterministic names a real divergence — a genuinely different step count" do
      # Not a manufactured non-determinism (the runtime does not have
      # one to hand) — a wrong claim that two DIFFERENT step lists are
      # "the same replay" is exactly what this property exists to catch,
      # so this proves the comparison itself is sensitive to real drift.
      first  = Hecksagain::Fuzzing::Replay.call(PROPERTIES_PIZZAS, [])
      second = Hecksagain::Fuzzing::Replay.call(
        PROPERTIES_PIZZAS,
        [{ "verb" => "Pizzas::Order.CreatePizza",
           "args" => { "name" => { "value" => "X" },
                       "pizza" => { "price_cents" => { "cents" => 100 }, "size" => { "value" => "small" } } } }]
      )
      comparable = ->(h) { h.reject { |k, _| k == :bluebook || k == :bluebooks } }

      expect(comparable.call(first)).not_to eq(comparable.call(second))
    end

    # ATMCard.ByFee — real corpus, `order_by :daily_fee; limit 3; offset
    # 1`. Four active cards, distinct fees; the true offset-1/limit-3 page
    # is cards 2-4.
    it "paging_offset_partitions_correctly names an answer that disagrees with the recomputed page" do
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  instances: {
                    "Banking::ATMCard#s1" => { status: "active", daily_fee: { amount: 1.0 }, serial: { value: "s1" } },
                    "Banking::ATMCard#s2" => { status: "active", daily_fee: { amount: 2.0 }, serial: { value: "s2" } },
                    "Banking::ATMCard#s3" => { status: "active", daily_fee: { amount: 3.0 }, serial: { value: "s3" } },
                    "Banking::ATMCard#s4" => { status: "active", daily_fee: { amount: 4.0 }, serial: { value: "s4" } }
                  },
                  queries: [{ query: "Banking::ATMCard.ByFee", args: {},
                             rows: [{ id: "s1", status: "active", daily_fee: { amount: 1.0 }, serial: { value: "s1" } }] }] }

      result = Hecksagain::Fuzzing::Properties.paging_offset_partitions_correctly(history)
      expect(result).to be_a(String)
      expect(result).to include("Banking::ATMCard.ByFee").and include("4 eligible row(s)")
    end

    it "paging_offset_partitions_correctly passes an answer that skips before it takes" do
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  instances: {
                    "Banking::ATMCard#s1" => { status: "active", daily_fee: { amount: 1.0 }, serial: { value: "s1" } },
                    "Banking::ATMCard#s2" => { status: "active", daily_fee: { amount: 2.0 }, serial: { value: "s2" } },
                    "Banking::ATMCard#s3" => { status: "active", daily_fee: { amount: 3.0 }, serial: { value: "s3" } },
                    "Banking::ATMCard#s4" => { status: "active", daily_fee: { amount: 4.0 }, serial: { value: "s4" } }
                  },
                  queries: [{ query: "Banking::ATMCard.ByFee", args: {},
                             rows: [
                               { id: "s2", status: "active", daily_fee: { amount: 2.0 }, serial: { value: "s2" } },
                               { id: "s3", status: "active", daily_fee: { amount: 3.0 }, serial: { value: "s3" } },
                               { id: "s4", status: "active", daily_fee: { amount: 4.0 }, serial: { value: "s4" } }
                             ] }] }

      expect(Hecksagain::Fuzzing::Properties.paging_offset_partitions_correctly(history)).to eq(true)
    end

    # SafeDepositBox.Rented — real corpus, `where(status: "rented"); order_by
    # :branch_code; authorize :vault_access, tenant: :branch_code`.
    it "authorize_scopes_or_refuses names a successful answer whose tenant field disagrees with the given arg" do
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  queries: [{ query: "Banking::SafeDepositBox.Rented", args: { branch_code: "DOWNTOWN" },
                             rows: [{ id: "UPTOWN:1", branch_code: { value: "UPTOWN" }, box_number: { value: 1 },
                                      status: "rented" }] }] }

      result = Hecksagain::Fuzzing::Properties.authorize_scopes_or_refuses(history)
      expect(result).to be_a(String)
      expect(result).to include("Banking::SafeDepositBox.Rented").and include("UPTOWN")
    end

    it "authorize_scopes_or_refuses names a successful answer with no tenant arg given at all" do
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  queries: [{ query: "Banking::SafeDepositBox.Rented", args: {},
                             rows: [{ id: "DOWNTOWN:12", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                      status: "rented" }] }] }

      result = Hecksagain::Fuzzing::Properties.authorize_scopes_or_refuses(history)
      expect(result).to be_a(String)
      expect(result).to include("Banking::SafeDepositBox.Rented")
    end

    it "authorize_scopes_or_refuses names a refusal with no tenant given that used the wrong wording" do
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  queries: [{ query: "Banking::SafeDepositBox.Rented", args: {}, error: "a made up refusal" }] }

      result = Hecksagain::Fuzzing::Properties.authorize_scopes_or_refuses(history)
      expect(result).to be_a(String)
      expect(result).to include("Banking::SafeDepositBox.Rented").and include("a made up refusal")
    end

    it "authorize_scopes_or_refuses passes a successful answer whose tenant field matches the given arg, and a correctly-worded refusal with no tenant" do
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  queries: [
                    { query: "Banking::SafeDepositBox.Rented", args: { branch_code: "DOWNTOWN" },
                      rows: [{ id: "DOWNTOWN:12", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                               status: "rented" }] },
                    { query: "Banking::SafeDepositBox.Rented", args: {},
                      error: "Rented declares authorize with tenant: branch_code — pass branch_code: to name " \
                             "which branch_code this ask is scoped to" }
                  ] }

      expect(Hecksagain::Fuzzing::Properties.authorize_scopes_or_refuses(history)).to eq(true)
    end

    it "dispatch_binding_fidelity names a saga dispatch bound to the wrong value" do
      history = { saga_dispatches: [
        { process_manager: "Settlement", instance: "ref-1", dispatch: "Account::Credit", on: "AccountDebited",
          correlation_head: :reference, event_payload: { source: "a1", destination: "a2", amount: 500 },
          memory: { destination: "a2" }, with_spec: { number: :destination, amount: :amount },
          args: { number: "WRONG", amount: 500 } }
      ] }

      result = Hecksagain::Fuzzing::Properties.dispatch_binding_fidelity(history)
      expect(result).to be_a(String)
      expect(result).to include("Settlement").and include("Account::Credit").and include("WRONG")
    end

    it "dispatch_binding_fidelity names a policy trigger bound to the wrong value" do
      history = { policy_dispatches: [
        { policy: "NotifyOnDebit", on: "AccountDebited", payload: { account: "a1", amount: 500 },
          with_spec: { account_ref: :account }, args: { account_ref: "WRONG" } }
      ] }

      result = Hecksagain::Fuzzing::Properties.dispatch_binding_fidelity(history)
      expect(result).to be_a(String)
      expect(result).to include("NotifyOnDebit").and include("WRONG")
    end

    # ALL FOUR SagaInterpreter#dispatch_args BRANCHES, in one entry —
    # literal (`narrative:`), correlation-head (`transfer:`),
    # current-event-payload (`amount:`), and saga-memory-fallback
    # (`number:`, absent from event_payload, present only in memory) —
    # plus a policy trigger's own 2-branch resolution (literal, payload).
    it "dispatch_binding_fidelity passes saga and policy dispatches correctly bound on every resolution branch" do
      history = {
        saga_dispatches: [
          { process_manager: "Settlement", instance: "ref-1", dispatch: "Account::Credit", on: "AccountDebited",
            correlation_head: :reference, event_payload: { source: "a1", amount: 500 },
            memory: { destination: "a2" },
            with_spec: { number: :destination, amount: :amount, transfer: :reference,
                         narrative: { text: "transfer in" } },
            args: { number: "a2", amount: 500, transfer: "ref-1", narrative: { text: "transfer in" } } }
        ],
        policy_dispatches: [
          { policy: "NotifyOnDebit", on: "AccountDebited", payload: { account: "a1", amount: 500 },
            with_spec: { account_ref: :account, reason: "debited" },
            args: { account_ref: "a1", reason: "debited" } }
        ]
      }

      expect(Hecksagain::Fuzzing::Properties.dispatch_binding_fidelity(history)).to eq(true)
    end

    it "mutations_match_recompute names an append whose after-state disagrees with the recomputed element" do
      history = { bluebooks: bluebooks_for(PROPERTIES_ENTITY_MUTATIONS),
                  mutation_traces: [
                    { verb: "EntityListMutations::Board.TaggedList.AddTag",
                      before: { label: { value: "l1" }, count: { value: 0 }, tags: [] },
                      after: { label: { value: "l1" }, count: { value: 0 }, tags: [] },
                      args: { key: "k1", value: "v1", name: { value: "b1" }, label: { value: "l1" } } }
                  ] }

      result = Hecksagain::Fuzzing::Properties.mutations_match_recompute(history)
      expect(result).to be_a(String)
      expect(result).to include("AddTag").and include("append")
    end

    it "mutations_match_recompute names a clamp whose after-state disagrees with the recomputed bound" do
      history = { bluebooks: bluebooks_for(PROPERTIES_ENTITY_MUTATIONS),
                  mutation_traces: [
                    { verb: "EntityListMutations::Board.TaggedList.Clamp",
                      before: { label: { value: "l1" }, count: { value: 15 } },
                      after: { label: { value: "l1" }, count: { value: 15 } },
                      args: { name: { value: "b1" }, label: { value: "l1" } } }
                  ] }

      result = Hecksagain::Fuzzing::Properties.mutations_match_recompute(history)
      expect(result).to be_a(String)
      expect(result).to include("Clamp").and include("clamp")
    end

    it "mutations_match_recompute passes append/remove/multiply/clamp all correctly recomputed" do
      history = { bluebooks: bluebooks_for(PROPERTIES_ENTITY_MUTATIONS),
                  mutation_traces: [
                    { verb: "EntityListMutations::Board.TaggedList.AddTag",
                      before: { label: { value: "l1" }, count: { value: 0 }, tags: [] },
                      after: { label: { value: "l1" }, count: { value: 0 }, tags: [{ key: "k1", value: "v1" }] },
                      args: { key: "k1", value: "v1", name: { value: "b1" }, label: { value: "l1" } } },
                    { verb: "EntityListMutations::Board.TaggedList.RemoveTag",
                      before: { label: { value: "l1" }, count: { value: 0 }, tags: [{ key: "k1", value: "v1" }] },
                      after: { label: { value: "l1" }, count: { value: 0 }, tags: [] },
                      args: { tag: { "key" => "k1", "value" => "v1" }, name: { value: "b1" }, label: { value: "l1" } } },
                    { verb: "EntityListMutations::Board.TaggedList.Scale",
                      before: { label: { value: "l1" }, count: { value: 4 } },
                      after: { label: { value: "l1" }, count: { value: 12 } },
                      args: { factor: 3, name: { value: "b1" }, label: { value: "l1" } } },
                    { verb: "EntityListMutations::Board.TaggedList.Clamp",
                      before: { label: { value: "l1" }, count: { value: 15 } },
                      after: { label: { value: "l1" }, count: { value: 10 } },
                      args: { name: { value: "b1" }, label: { value: "l1" } } }
                  ] }

      expect(Hecksagain::Fuzzing::Properties.mutations_match_recompute(history)).to eq(true)
    end

    it "guard_refusals_are_declared names a refusal quoting text no given/ensures on the command declares" do
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  refusals: [{ verb: "Banking::Account.Credit", error: "Credit refused — a made up reason",
                              kind: "Hecksagain::Runtime::GivenNotMet" }] }

      result = Hecksagain::Fuzzing::Properties.guard_refusals_are_declared(history)
      expect(result).to be_a(String)
      expect(result).to include("a made up reason")
    end

    it "guard_refusals_are_declared passes a refusal quoting the command's own declared given through" do
      # "customer is active" — S10, ADR 0025's named precondition, not
      # typed on Credit directly any more (Account.given, referenced
      # back) — but still a real entry in Credit.givens either way,
      # which is the only thing this property reads. "the account is
      # open" (this test's own text before S10) is GONE from Credit
      # entirely now — S10 made it a lifecycle guard, `from: "open"`,
      # which raises LifecycleRefused, never GivenNotMet, so it could
      # not stand in for "a real given" here even unchanged.
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  refusals: [{ verb: "Banking::Account.Credit", error: "Credit refused — customer is active",
                              kind: "Hecksagain::Runtime::GivenNotMet" }] }

      expect(Hecksagain::Fuzzing::Properties.guard_refusals_are_declared(history)).to eq(true)
    end

    it "guard_refusals_are_declared resolves a refusal against ITS OWN domain, not just the first-loaded one" do
      # THE REAL REGRESSION, pinned exactly as bin/fuzz found it: a
      # domain under fuzz commonly composes more than one bluebook
      # (Expression loads before Translation here) — a genuine given
      # refusal from a NON-first domain used to read as "no declared
      # command resolves that verb," purely because command_for_verb only
      # ever consulted whichever bluebook happened to load first, never
      # the refusing verb's OWN domain.
      bluebooks = bluebooks_for(PROPERTIES_GRAMMAR)
      # Expression loads first — the shape the bug needed. Governance
      # loads last — both Expression's and Translation's hecksagons now
      # `uses_framework "Governance"` (S8: `role` is only real access
      # control once Governance can check it), attached AFTER either
      # chapter itself, since `uses_framework` runs from inside their
      # own hecksagon blocks.
      expect(bluebooks.keys).to eq(%w[Expression Translation Governance])

      history = { bluebooks: bluebooks,
                  refusals: [{ verb: "Translation::Map.Seal",
                              error: "Seal refused — an empty edge explains nothing",
                              kind: "Hecksagain::Runtime::GivenNotMet" }] }

      expect(Hecksagain::Fuzzing::Properties.guard_refusals_are_declared(history)).to eq(true)
    end

    it "guard_refusals_are_declared ignores a refusal sharing the same wording but a DIFFERENT raised class" do
      # LifecycleRefused/transition_blocked shares GivenNotMet's exact
      # "X refused — Y" shape (RefusalWording's own template) — a
      # refusal identified by string alone would misread this as an
      # undeclared guard; identified by `kind:`, it is skipped outright.
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  refusals: [{ verb: "Banking::Account.CloseAccount",
                              error: "CloseAccount refused — status is closed, and CloseAccount moves it only from open, frozen",
                              kind: "Hecksagain::Runtime::LifecycleRefused" }] }

      expect(Hecksagain::Fuzzing::Properties.guard_refusals_are_declared(history)).to eq(true)
    end

    it "lifecycle_guard_and_given_violations_are_refused names a step the guard should have refused but didn't" do
      history = { guard_checks: [
        { verb: "Banking::Account.Debit", recomputed_refused: true, recomputed_kind: "Hecksagain::Runtime::GivenNotMet",
          actual_refused: false, actual_kind: nil }
      ] }

      result = Hecksagain::Fuzzing::Properties.lifecycle_guard_and_given_violations_are_refused(history)
      expect(result).to be_a(String)
      expect(result).to include("Banking::Account.Debit").and include("refused").and include("admitted")
    end

    it "lifecycle_guard_and_given_violations_are_refused names a step the guard refused but shouldn't have" do
      history = { guard_checks: [
        { verb: "Banking::Account.Credit", recomputed_refused: false, recomputed_kind: nil,
          actual_refused: true, actual_kind: "Hecksagain::Runtime::LifecycleRefused" }
      ] }

      result = Hecksagain::Fuzzing::Properties.lifecycle_guard_and_given_violations_are_refused(history)
      expect(result).to be_a(String)
      expect(result).to include("Banking::Account.Credit")
    end

    it "lifecycle_guard_and_given_violations_are_refused passes when the recomputed and actual verdicts agree" do
      history = { guard_checks: [
        { verb: "Banking::Account.Debit", recomputed_refused: false, recomputed_kind: nil,
          actual_refused: false, actual_kind: nil },
        { verb: "Banking::Account.CloseAccount", recomputed_refused: true, recomputed_kind: "Hecksagain::Runtime::LifecycleRefused",
          actual_refused: true, actual_kind: "Hecksagain::Runtime::LifecycleRefused" }
      ] }

      expect(Hecksagain::Fuzzing::Properties.lifecycle_guard_and_given_violations_are_refused(history)).to eq(true)
    end

    it "sagas_rehydrate_cleanly names a live instance holding a state its process manager never declares" do
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  saga_instances: { "Onboarding" => { "corr-1" => { state: "teleported", memory: { a: 1 } } } } }

      result = Hecksagain::Fuzzing::Properties.sagas_rehydrate_cleanly(history)
      expect(result).to be_a(String)
      expect(result).to include("teleported")
    end

    it "sagas_rehydrate_cleanly names a memory that does not survive its own checkpoint round-trip" do
      # A bare Symbol LEAF — `deep_copy`'s own JSON round-trip (the exact
      # write/read a real `save_saga`/`each_saga` adapter performs) reads
      # a Symbol value back as a String, so this is corruption the
      # durable path would introduce on a REAL restart, not a
      # hypothetical one.
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  saga_instances: { "Onboarding" => { "corr-1" => { state: "screening", memory: { kind: :wire } } } } }

      result = Hecksagain::Fuzzing::Properties.sagas_rehydrate_cleanly(history)
      expect(result).to be_a(String)
      expect(result).to include("does not survive its own checkpoint round-trip")
    end

    it "sagas_rehydrate_cleanly passes a genuinely declared state and round-trip-safe memory through" do
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  saga_instances: { "Onboarding" => { "corr-1" =>
                    { state: "screening", memory: { customer: "delta juliet", reference: { value: "corr-1" } } } } } }

      expect(Hecksagain::Fuzzing::Properties.sagas_rehydrate_cleanly(history)).to eq(true)
    end

    it "fanout_dispatches_once_per_matching_row names a row the reaction log missed" do
      history = { fan_outs: [{ policy: "ReviewOnFlag", on: "Flagged",
                              expected_row_ids: ["a1", "a2"], actual_row_ids: ["a1"] }] }

      result = Hecksagain::Fuzzing::Properties.fanout_dispatches_once_per_matching_row(history)
      expect(result).to be_a(String)
      expect(result).to include('["a1", "a2"]').and include('["a1"]')
    end

    it "fanout_dispatches_once_per_matching_row names a dispatch that fired despite a failing where" do
      history = { fan_outs: [{ policy: "ReviewOnFlag", on: "Flagged",
                              expected_row_ids: nil, actual_row_ids: ["a1"] }] }

      result = Hecksagain::Fuzzing::Properties.fanout_dispatches_once_per_matching_row(history)
      expect(result).to be_a(String)
      expect(result).to include("where did not hold")
    end

    it "fanout_dispatches_once_per_matching_row passes an exact match, and a guarded no-op, through" do
      history = { fan_outs: [
        { policy: "ReviewOnFlag", on: "Flagged", expected_row_ids: ["a1", "a2"], actual_row_ids: ["a2", "a1"] },
        { policy: "ReviewOnFlag", on: "Flagged", expected_row_ids: nil, actual_row_ids: [] }
      ] }

      expect(Hecksagain::Fuzzing::Properties.fanout_dispatches_once_per_matching_row(history)).to eq(true)
    end

    it "aggregation_matches_recompute names a count that disagrees with the recomputed eligible rows" do
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  instances: {
                    "Banking::CardPayment#p1" => { account: "acct-1", status: "disputed" },
                    "Banking::CardPayment#p2" => { account: "acct-1", status: "disputed" },
                    "Banking::CardPayment#p3" => { account: "acct-1", status: "authorized" }
                  },
                  queries: [{ query: "Banking.disputed_payment_count", args: { account: "acct-1" },
                             rows: [{ account: {}, card_payments: 99 }] }] }

      result = Hecksagain::Fuzzing::Properties.aggregation_matches_recompute(history)
      expect(result).to be_a(String)
      expect(result).to include("99").and include("2")
    end

    it "aggregation_matches_recompute passes a count that matches the recomputed eligible rows" do
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  instances: {
                    "Banking::CardPayment#p1" => { account: "acct-1", status: "disputed" },
                    "Banking::CardPayment#p2" => { account: "acct-1", status: "disputed" },
                    "Banking::CardPayment#p3" => { account: "acct-1", status: "authorized" },
                    "Banking::CardPayment#p4" => { account: "acct-2", status: "disputed" }
                  },
                  queries: [{ query: "Banking.disputed_payment_count", args: { account: "acct-1" },
                             rows: [{ account: {}, card_payments: 2 }] }] }

      expect(Hecksagain::Fuzzing::Properties.aggregation_matches_recompute(history)).to eq(true)
    end

    it "aggregation_matches_recompute passes a median matching the interpreter's own even/odd convention" do
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  instances: {
                    "Banking::CardPayment#p1" => { account: "acct-1", status: "disputed", amount: { cents: 100 } },
                    "Banking::CardPayment#p2" => { account: "acct-1", status: "disputed", amount: { cents: 300 } }
                  },
                  queries: [{ query: "Banking.disputed_payment_median", args: { account: "acct-1" },
                             rows: [{ account: {}, card_payments: 200.0 }] }] }

      expect(Hecksagain::Fuzzing::Properties.aggregation_matches_recompute(history)).to eq(true)
    end

    it "stored_records_satisfy_declared_invariants names a stored balance that violates Account's own invariant" do
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  instances: { "Banking::Account#a1" => { balance: { cents: -500, currency: "USD" } } } }

      result = Hecksagain::Fuzzing::Properties.stored_records_satisfy_declared_invariants(history)
      expect(result).to be_a(String)
      expect(result).to include("Banking::Account#a1").and include("the balance never goes negative")
    end

    it "stored_records_satisfy_declared_invariants passes a stored balance that holds the invariant" do
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  instances: { "Banking::Account#a1" => { balance: { cents: 500, currency: "USD" } } } }

      expect(Hecksagain::Fuzzing::Properties.stored_records_satisfy_declared_invariants(history)).to eq(true)
    end

    # AccountsByKind — real corpus, group_by :kind, :number, rootless. The
    # instances here supply :kind/:number as BARE strings rather than real
    # Kind{name}/Number{value} VOs — Value.materialize_unwrapped is a no-op
    # on an already-bare String either way (the `when self` single-VO-
    # unwrap branch only ever fires on a REAL Value instance), so this
    # exercises the grouping/nesting recomputation itself without needing
    # to hand-construct real Value objects for a hand-built history — the
    # single-VO unwrap is ReadModelInterpreter's own spec's job, not this
    # oracle's.
    it "group_by_matches_recompute names a grouping that disagrees with the recomputed nesting" do
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  instances: {
                    "Banking::Account#a1" => { kind: "current", number: "a1", daily_limit: { cents: 0 } },
                    "Banking::Account#a2" => { kind: "savings", number: "a2", daily_limit: { cents: 0 } },
                    "Banking::Account#a3" => { kind: "current", number: "a3", daily_limit: { cents: 0 } }
                  },
                  queries: [{ query: "Banking.accounts_by_kind", args: {},
                             rows: [{ accounts: {} }] }] }

      result = Hecksagain::Fuzzing::Properties.group_by_matches_recompute(history)
      expect(result).to be_a(String)
      expect(result).to include("Banking.accounts_by_kind").and include("3 eligible row(s)")
    end

    it "group_by_matches_recompute passes a grouping that matches the recomputed nesting" do
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  instances: {
                    "Banking::Account#a1" => { kind: "current", number: "a1", daily_limit: { cents: 0 } },
                    "Banking::Account#a2" => { kind: "savings", number: "a2", daily_limit: { cents: 0 } }
                  },
                  queries: [{ query: "Banking.accounts_by_kind", args: {},
                             rows: [{ accounts: {
                               "current" => { "a1" => { daily_limit: { cents: 0 }, id: "a1" } },
                               "savings" => { "a2" => { daily_limit: { cents: 0 }, id: "a2" } }
                             } }] }] }

      expect(Hecksagain::Fuzzing::Properties.group_by_matches_recompute(history)).to eq(true)
    end
  end
end
