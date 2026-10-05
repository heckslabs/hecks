require "spec_helper"
require "hecks/fuzzing"

# Declared properties over generated histories. Two directions: the
# standard battery holds over real generated sequences (below), and
# each property fires against a hand-built history that violates it —
# a property that can never fail is decoration.
RSpec.describe "Hecks::Fuzzing::Properties" do
  ROOT_DIR = InMemoryDomain::ROOT unless defined?(ROOT_DIR)
  PROPERTIES_PIZZAS   = File.join(ROOT_DIR, "examples/pizzas")
  PROPERTIES_BANKING  = File.join(ROOT_DIR, "examples/banking")
  PROPERTIES_FIXTURES = File.join(ROOT_DIR, "spec/fixtures")
  # A real bootable domain (no .hecksagon — Memory by construction), and
  # the only corpus site using entity-owned append/remove/multiply/clamp.
  PROPERTIES_ENTITY_MUTATIONS = File.join(ROOT_DIR, "spec/fixtures/entity_list_mutations")
  # The only corpus site combining an entity-owned :append (Board.AddCard)
  # with a VO-typed appended field (sequence, CardSequence-typed) — this
  # exercises recompute_append's type-aware coercion, which bare-String
  # append targets elsewhere never do.
  PROPERTIES_NESTED_PIECES = File.join(ROOT_DIR, "qa/stress_domains/nested_pieces")
  # The self-hosted meta-domain — Expression + Translation, in that load
  # order — pins a multi-bluebook regression: `command_for_verb` only
  # consulting whichever bluebook loaded first misread every genuine
  # `Translation::Map.Seal` refusal as unresolvable.
  PROPERTIES_GRAMMAR = File.join(ROOT_DIR, "lib/hecks/grammar")
  # The one domain whose `group_by` can collide (ADR 0061, decision D1).
  PROPERTIES_GROUP_BY_COLLISION = File.join(ROOT_DIR, "spec/fixtures/rust_project/group_by_collision_fixture")

  # `adapter:` only picks replay's repository; generation always stays Memory (isolated_boot.rb).
  def generated_history(domain, seed, adapter: :memory)
    steps = Hecks::Fuzzing::SequenceGenerator.generate(domain, seed: seed, steps: 25)
    Hecks::Fuzzing::Replay.call(domain, steps, adapter: adapter)
  end

  describe "the standard battery, over real generated sequences" do
    [[PROPERTIES_PIZZAS, 5], [PROPERTIES_BANKING, 5], [PROPERTIES_ENTITY_MUTATIONS, 10],
     [PROPERTIES_NESTED_PIECES, 40]].each do |domain, seed_count|
      it "holds for #{File.basename(domain)} across #{seed_count} seeds" do
        (1..seed_count).each do |seed|
          history = generated_history(domain, seed)
          results = Hecks::Fuzzing::Properties.check(history)

          results.each do |property, result|
            expect(result).to be(true), "#{domain} seed #{seed} — #{property}: #{result}"
          end
        end
      end

      it "stays deterministic for #{File.basename(domain)} across #{seed_count} seeds" do
        (1..seed_count).each do |seed|
          steps = Hecks::Fuzzing::SequenceGenerator.generate(domain, seed: seed, steps: 25)
          result = Hecks::Fuzzing::Properties.replay_is_deterministic(domain, steps)

          expect(result).to be(true), "#{domain} seed #{seed}: #{result}"
        end
      end
    end
  end

  # Runs the identical standard battery again, same domains and seeds,
  # against real SQLite — a genuinely different code path (SqlQueryBuilder
  # SQL compilation) than Memory's Hash-based Ports::Query::InMemory.
  #
  # PROPERTIES_ENTITY_MUTATIONS is excluded: it ships with no .hecksagon
  # (Memory by construction), so `adapter: :sqlite` would silently stay
  # Memory, claiming coverage it doesn't have.
  #
  # Postgres/PostgresEra stay `io: true`-gated (spec/adapters/driven/
  # postgres_*_spec.rb): a real server has no safe place to come from in
  # an unconditional, always-on local spec.
  describe "the standard battery, over real generated sequences, against real SQLite" do
    [[PROPERTIES_PIZZAS, 5], [PROPERTIES_BANKING, 5]].each do |domain, seed_count|
      it "holds for #{File.basename(domain)} across #{seed_count} seeds" do
        (1..seed_count).each do |seed|
          history = generated_history(domain, seed, adapter: :sqlite)
          results = Hecks::Fuzzing::Properties.check(history)

          results.each do |property, result|
            expect(result).to be(true), "#{domain} seed #{seed} (sqlite) — #{property}: #{result}"
          end
        end
      end
    end
  end

  describe "each property, seen failing" do
    def bluebook_for(domain)
      Hecks::Fuzzing::Replay.call(domain, [])[:bluebook]
    end

    def bluebooks_for(domain)
      Hecks::Fuzzing::Replay.call(domain, [])[:bluebooks]
    end

    # Two parts in bin b1, one in b2 — bare strings, matching AccountsByKind's shape below.
    def colliding_parts
      {
        "GroupByCollisionFixture::Part#p1" => { bin: "b1", ref: "p1" },
        "GroupByCollisionFixture::Part#p2" => { bin: "b1", ref: "p2" },
        "GroupByCollisionFixture::Part#p3" => { bin: "b2", ref: "p3" }
      }
    end

    it "lifecycle_values_are_declared names an instance holding an undeclared state" do
      history = { bluebook:  bluebook_for(PROPERTIES_PIZZAS),
                  instances: { "Pizzas::Order#p1" => { status: "teleported" } } }

      result = Hecks::Fuzzing::Properties.lifecycle_values_are_declared(history)
      expect(result).to be_a(String)
      expect(result).to include("teleported")
    end

    it "lifecycle_values_are_declared passes a genuinely declared state through" do
      history = { bluebook:  bluebook_for(PROPERTIES_PIZZAS),
                  instances: { "Pizzas::Order#p1" => { status: "available" } } }

      expect(Hecks::Fuzzing::Properties.lifecycle_values_are_declared(history)).to be(true)
    end

    it "saga_advances_follow_declared_handlers names an advance no handler declares" do
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  sagas:    [{ process_manager: "Settlement", on: "Invented", instance: "x",
                            advanced: true, from: "requested", to: "nowhere_declared" }] }

      result = Hecks::Fuzzing::Properties.saga_advances_follow_declared_handlers(history)
      expect(result).to be_a(String)
      expect(result).to include("nowhere_declared")
    end

    it "saga_advances_follow_declared_handlers passes a genuinely declared edge through" do
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  sagas:    [{ process_manager: "Settlement", on: "TransferRequested", instance: "x",
                            advanced: true, from: "requested", to: "requested" }] }

      expect(Hecks::Fuzzing::Properties.saga_advances_follow_declared_handlers(history)).to be(true)
    end

    it "query_answers_match_reference names a native answer the reference interpreter disputes" do
      history = { queries: [{ query: "Pizzas::Order.Expensive", args: {},
                              rows: [{ id: "Margherita" }],
                              reference_rows: [] }] }

      result = Hecks::Fuzzing::Properties.query_answers_match_reference(history)
      expect(result).to be_a(String)
      expect(result).to include("Pizzas::Order.Expensive").and include("natively")
    end

    it "query_answers_match_reference passes agreement, refusals, and read-model asks through" do
      history = { queries: [
        { query: "Pizzas::Order.Expensive", args: {}, rows: [{ id: "M" }], reference_rows: [{ id: "M" }] },
        # Both engines refused, in agreement — not a finding, modeled with
        # both error: and reference_error: present (the shape Replay
        # produces when both engines raise independently).
        { query: "Pizzas::Order.Expensive", args: {}, error: "refused", reference_error: "refused" },
        { query: "Pizzas.some_read_model", args: {}, rows: [] }
      ] }

      expect(Hecks::Fuzzing::Properties.query_answers_match_reference(history)).to be(true)
    end

    # Pins a refusal-shaped divergence — one engine refusing while the
    # other answers — as something the property must be able to name,
    # not something a shared rescue silently discards.
    it "query_answers_match_reference names a refusal-shaped divergence — one engine refused, the other didn't" do
      history = { queries: [
        { query: "Pizzas::Order.Expensive", args: {}, rows: [{ id: "Margherita" }], reference_error: "reference refused" }
      ] }

      result = Hecks::Fuzzing::Properties.query_answers_match_reference(history)
      expect(result).to be_a(String)
      expect(result).to include("Pizzas::Order.Expensive").and include("divergence")
    end

    it "query_answers_match_reference names the reverse refusal-shaped divergence too — reference refused, native didn't" do
      history = { queries: [
        { query: "Pizzas::Order.Expensive", args: {}, error: "native refused", reference_rows: [{ id: "Margherita" }] }
      ] }

      result = Hecks::Fuzzing::Properties.query_answers_match_reference(history)
      expect(result).to be_a(String)
      expect(result).to include("Pizzas::Order.Expensive").and include("divergence")
    end

    it "replay_is_deterministic names a real divergence — a genuinely different step count" do
      # Not a manufactured non-determinism (the runtime does not have
      # one to hand) — a wrong claim that two different step lists are
      # "the same replay" is exactly what this property exists to catch,
      # so this proves the comparison itself is sensitive to real drift.
      first  = Hecks::Fuzzing::Replay.call(PROPERTIES_PIZZAS, [])
      second = Hecks::Fuzzing::Replay.call(
        PROPERTIES_PIZZAS,
        [{ "verb" => "Pizzas::Order.CreatePizza",
           "args" => { "name"  => { "value" => "X" },
                       "pizza" => { "price_cents" => { "cents" => 100 }, "size" => { "value" => "small" } } } }]
      )
      comparable = ->(h) { h.except(:bluebook, :bluebooks) }

      expect(comparable.call(first)).not_to eq(comparable.call(second))
    end

    # ATMCard.ByFee — real corpus, `order_by :daily_fee; limit 3; offset
    # 1`. Four active cards, distinct fees; the true offset-1/limit-3 page
    # is cards 2-4.
    it "paging_offset_partitions_correctly names an answer that disagrees with the recomputed page" do
      instances = {
        "Banking::ATMCard#s1" => { status: "active", daily_fee: { amount: 1.0 }, serial: { value: "s1" } },
        "Banking::ATMCard#s2" => { status: "active", daily_fee: { amount: 2.0 }, serial: { value: "s2" } },
        "Banking::ATMCard#s3" => { status: "active", daily_fee: { amount: 3.0 }, serial: { value: "s3" } },
        "Banking::ATMCard#s4" => { status: "active", daily_fee: { amount: 4.0 }, serial: { value: "s4" } }
      }
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  queries:   [{ query: "Banking::ATMCard.ByFee", args: {}, instances_at: instances,
                             rows: [{ id: "s1", status: "active", daily_fee: { amount: 1.0 }, serial: { value: "s1" } }] }] }

      result = Hecks::Fuzzing::Properties.paging_offset_partitions_correctly(history)
      expect(result).to be_a(String)
      expect(result).to include("Banking::ATMCard.ByFee").and include("4 eligible row(s)")
    end

    it "paging_offset_partitions_correctly passes an answer that skips before it takes" do
      instances = {
        "Banking::ATMCard#s1" => { status: "active", daily_fee: { amount: 1.0 }, serial: { value: "s1" } },
        "Banking::ATMCard#s2" => { status: "active", daily_fee: { amount: 2.0 }, serial: { value: "s2" } },
        "Banking::ATMCard#s3" => { status: "active", daily_fee: { amount: 3.0 }, serial: { value: "s3" } },
        "Banking::ATMCard#s4" => { status: "active", daily_fee: { amount: 4.0 }, serial: { value: "s4" } }
      }
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  queries:   [{ query: "Banking::ATMCard.ByFee", args: {}, instances_at: instances,
                             rows: [
                               { id: "s2", status: "active", daily_fee: { amount: 2.0 }, serial: { value: "s2" } },
                               { id: "s3", status: "active", daily_fee: { amount: 3.0 }, serial: { value: "s3" } },
                               { id: "s4", status: "active", daily_fee: { amount: 4.0 }, serial: { value: "s4" } }
                             ] }] }

      expect(Hecks::Fuzzing::Properties.paging_offset_partitions_correctly(history)).to be(true)
    end

    # HopChain::Proposal.PricedAboveViaEngagement — real corpus, `where
    # :"engagement/client/status" => "active"` — a `/` hop clause, which a
    # recompute treating it as a local dotted path would falsely flag as
    # 0-eligible (see Properties#query_eligible_rows). Every field in the
    # chain is a single-attribute value object, so this also pins shape
    # and paging through the recompute. Two directions: accept when the
    # hop's far end genuinely holds, and still name a violation when it
    # doesn't.
    it "paging_offset_partitions_correctly resolves a / hop clause the way the live fold does, and passes the answer" do
      instances = {
        "HopChain::Client#juliet"      => { name: { value: "juliet" }, status: "active" },
        "HopChain::Engagement#charlie" => { client: "juliet", reference: { value: "charlie" }, stage: "started" },
        "HopChain::Proposal#p1"        => { engagement: "charlie", number: { value: "p1" }, status: "drafted" }
      }
      history = { bluebooks: bluebooks_for(PROPERTIES_FIXTURES),
                  queries:   [{ query: "HopChain::Proposal.PricedAboveViaEngagement", args: {}, instances_at: instances,
                                rows: [{ id: "p1", engagement: "charlie", number: { value: "p1" }, status: "drafted" }] }] }

      expect(Hecks::Fuzzing::Properties.paging_offset_partitions_correctly(history)).to be(true)
    end

    it "paging_offset_partitions_correctly still names an answer whose hop's far end does not actually hold" do
      instances = {
        "HopChain::Client#juliet"      => { name: { value: "juliet" }, status: "churned" },
        "HopChain::Engagement#charlie" => { client: "juliet", reference: { value: "charlie" }, stage: "started" },
        "HopChain::Proposal#p1"        => { engagement: "charlie", number: { value: "p1" }, status: "drafted" }
      }
      history = { bluebooks: bluebooks_for(PROPERTIES_FIXTURES),
                  queries:   [{ query: "HopChain::Proposal.PricedAboveViaEngagement", args: {}, instances_at: instances,
                                rows: [{ id: "p1", engagement: "charlie", number: { value: "p1" }, status: "drafted" }] }] }

      result = Hecks::Fuzzing::Properties.paging_offset_partitions_correctly(history)
      expect(result).to be_a(String)
      expect(result).to include("HopChain::Proposal.PricedAboveViaEngagement").and include("0 eligible row(s)")
    end

    # SafeDepositBox.Rented — real corpus, `where(status: "rented"); order_by
    # :branch_code; authorize :vault_access, tenant: :branch_code`.
    it "authorize_scopes_or_refuses names a successful answer whose tenant field disagrees with the given arg" do
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  queries:   [{ query: "Banking::SafeDepositBox.Rented", args: { branch_code: "DOWNTOWN" },
                             rows: [{ id: "UPTOWN:1", branch_code: { value: "UPTOWN" }, box_number: { value: 1 },
                                      status: "rented" }] }] }

      result = Hecks::Fuzzing::Properties.authorize_scopes_or_refuses(history)
      expect(result).to be_a(String)
      expect(result).to include("Banking::SafeDepositBox.Rented").and include("UPTOWN")
    end

    it "authorize_scopes_or_refuses names a successful answer with no tenant arg given at all" do
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  queries:   [{ query: "Banking::SafeDepositBox.Rented", args: {},
                             rows: [{ id: "DOWNTOWN:12", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                                      status: "rented" }] }] }

      result = Hecks::Fuzzing::Properties.authorize_scopes_or_refuses(history)
      expect(result).to be_a(String)
      expect(result).to include("Banking::SafeDepositBox.Rented")
    end

    it "authorize_scopes_or_refuses names a refusal with no tenant given that used the wrong wording" do
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  queries:   [{ query: "Banking::SafeDepositBox.Rented", args: {}, error: "a made up refusal" }] }

      result = Hecks::Fuzzing::Properties.authorize_scopes_or_refuses(history)
      expect(result).to be_a(String)
      expect(result).to include("Banking::SafeDepositBox.Rented").and include("a made up refusal")
    end

    it "authorize_scopes_or_refuses passes a successful answer whose tenant field matches the given arg, " \
       "and a correctly-worded refusal with no tenant" do
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  queries:   [
                    { query: "Banking::SafeDepositBox.Rented", args: { branch_code: "DOWNTOWN" },
                      rows: [{ id: "DOWNTOWN:12", branch_code: { value: "DOWNTOWN" }, box_number: { value: 12 },
                               status: "rented" }] },
                    { query: "Banking::SafeDepositBox.Rented", args: {},
                      error: "Rented declares authorize with tenant: branch_code — pass branch_code: to name " \
                             "which branch_code this ask is scoped to" }
                  ] }

      expect(Hecks::Fuzzing::Properties.authorize_scopes_or_refuses(history)).to be(true)
    end

    it "dispatch_binding_fidelity names a saga dispatch bound to the wrong value" do
      history = { saga_dispatches: [
        { process_manager: "Settlement", instance: "ref-1", dispatch: "Account::Credit", on: "AccountDebited",
          correlation_head: :reference, event_payload: { source: "a1", destination: "a2", amount: 500 },
          memory: { destination: "a2" }, with_spec: { number: :destination, amount: :amount },
          args: { number: "WRONG", amount: 500 } }
      ] }

      result = Hecks::Fuzzing::Properties.dispatch_binding_fidelity(history)
      expect(result).to be_a(String)
      expect(result).to include("Settlement").and include("Account::Credit").and include("WRONG")
    end

    it "dispatch_binding_fidelity names a policy trigger bound to the wrong value" do
      history = { policy_dispatches: [
        { policy: "NotifyOnDebit", on: "AccountDebited", payload: { account: "a1", amount: 500 },
          with_spec: { account_ref: :account }, args: { account_ref: "WRONG" } }
      ] }

      result = Hecks::Fuzzing::Properties.dispatch_binding_fidelity(history)
      expect(result).to be_a(String)
      expect(result).to include("NotifyOnDebit").and include("WRONG")
    end

    # All four SagaInterpreter#dispatch_args branches, in one entry —
    # literal (`narrative:`), correlation-head (`transfer:`),
    # current-event-payload (`amount:`), and saga-memory-fallback
    # (`number:`, absent from event_payload, present only in memory) —
    # plus a policy trigger's own 2-branch resolution (literal, payload).
    it "dispatch_binding_fidelity passes saga and policy dispatches correctly bound on every resolution branch" do
      history = {
        saga_dispatches:   [
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

      expect(Hecks::Fuzzing::Properties.dispatch_binding_fidelity(history)).to be(true)
    end

    it "mutations_match_recompute names an append whose after-state disagrees with the recomputed element" do
      history = { bluebooks:       bluebooks_for(PROPERTIES_ENTITY_MUTATIONS),
                  mutation_traces: [
                    { verb:   "EntityListMutations::Board.TaggedList.AddTag",
                      before: { label: { value: "l1" }, count: { value: 0 }, tags: [] },
                      after:  { label: { value: "l1" }, count: { value: 0 }, tags: [] },
                      args:   { key: "k1", value: "v1", name: { value: "b1" }, label: { value: "l1" } } }
                  ] }

      result = Hecks::Fuzzing::Properties.mutations_match_recompute(history)
      expect(result).to be_a(String)
      expect(result).to include("AddTag").and include("append")
    end

    it "mutations_match_recompute names a clamp whose after-state disagrees with the recomputed bound" do
      history = { bluebooks:       bluebooks_for(PROPERTIES_ENTITY_MUTATIONS),
                  mutation_traces: [
                    { verb:   "EntityListMutations::Board.TaggedList.Clamp",
                      before: { label: { value: "l1" }, count: { value: 15 } },
                      after:  { label: { value: "l1" }, count: { value: 15 } },
                      args:   { name: { value: "b1" }, label: { value: "l1" } } }
                  ] }

      result = Hecks::Fuzzing::Properties.mutations_match_recompute(history)
      expect(result).to be_a(String)
      expect(result).to include("Clamp").and include("clamp")
    end

    it "mutations_match_recompute passes append/remove/multiply/clamp all correctly recomputed" do
      history = { bluebooks:       bluebooks_for(PROPERTIES_ENTITY_MUTATIONS),
                  mutation_traces: [
                    { verb:   "EntityListMutations::Board.TaggedList.AddTag",
                      before: { label: { value: "l1" }, count: { value: 0 }, tags: [] },
                      after:  { label: { value: "l1" }, count: { value: 0 }, tags: [{ key: "k1", value: "v1" }] },
                      args:   { key: "k1", value: "v1", name: { value: "b1" }, label: { value: "l1" } } },
                    { verb:   "EntityListMutations::Board.TaggedList.RemoveTag",
                      before: { label: { value: "l1" }, count: { value: 0 }, tags: [{ key: "k1", value: "v1" }] },
                      after:  { label: { value: "l1" }, count: { value: 0 }, tags: [] },
                      args:   { tag: { "key" => "k1", "value" => "v1" }, name: { value: "b1" }, label: { value: "l1" } } },
                    { verb:   "EntityListMutations::Board.TaggedList.Scale",
                      before: { label: { value: "l1" }, count: { value: 4 } },
                      after:  { label: { value: "l1" }, count: { value: 12 } },
                      args:   { factor: 3, name: { value: "b1" }, label: { value: "l1" } } },
                    { verb:   "EntityListMutations::Board.TaggedList.Clamp",
                      before: { label: { value: "l1" }, count: { value: 15 } },
                      after:  { label: { value: "l1" }, count: { value: 10 } },
                      args:   { name: { value: "b1" }, label: { value: "l1" } } }
                  ] }

      expect(Hecks::Fuzzing::Properties.mutations_match_recompute(history)).to be(true)
    end

    # Board.AddCard's `sets :cards, append: { sequence: :sequence }` targets
    # `sequence`, a CardSequence-typed (value-object) field — unlike
    # PROPERTIES_ENTITY_MUTATIONS' bare-String append targets, this is the
    # only corpus site combining an entity-owned :append with a VO-typed
    # appended field. The real dispatch coerces the bare scalar arg (821)
    # to CardSequence's sole attribute before EntityElement#
    # appended_to_element runs; this pins that recomputing independently
    # lands on that same coerced shape, not the raw scalar.
    it "mutations_match_recompute passes an entity-owned append whose target field is itself " \
       "value-object-typed (BUG#5)" do
      history = { bluebooks:       bluebooks_for(PROPERTIES_NESTED_PIECES),
                  mutation_traces: [
                    { verb:   "NestedPieces::Workspace.Board.AddCard",
                      before: { number: { value: 1 }, label: nil, cards: [] },
                      # nil, since Card.note (optional: true) isn't in
                      # AddCard's append mapping, but a freshly appended
                      # Card still carries the key, nil-valued regardless.
                      after:  { number: { value: 1 }, label: nil, cards: [{ sequence: { value: 821 }, note: nil }] },
                      args:   { number: { value: 1 }, sequence: 821 } }
                  ] }

      expect(Hecks::Fuzzing::Properties.mutations_match_recompute(history)).to be(true)
    end

    # Same before/args as the passing VO-typed-append example above — the
    # identical scalar 821 still coerces to { value: 821 } — except this
    # `after` claims { value: 999 } landed instead, a real mismatch
    # unrelated to VO-wrapping. Proves the comparison is coerced-against-
    # coerced, not skipping the field (which would miss exactly this).
    it "mutations_match_recompute still names a genuinely wrong VO-typed append, not merely a coercion artifact" do
      history = { bluebooks:       bluebooks_for(PROPERTIES_NESTED_PIECES),
                  mutation_traces: [
                    { verb:   "NestedPieces::Workspace.Board.AddCard",
                      before: { number: { value: 1 }, label: nil, cards: [] },
                      after:  { number: { value: 1 }, label: nil, cards: [{ sequence: { value: 999 } }] },
                      args:   { number: { value: 1 }, sequence: 821 } }
                  ] }

      result = Hecks::Fuzzing::Properties.mutations_match_recompute(history)
      expect(result).to be_a(String)
      expect(result).to include("AddCard").and include("append")
    end

    # NestedPieces::Workspace.Board.Label (`sets :label`, no append/remove/
    # multiply/clamp) is the real corpus site for an entity-owned plain
    # set, coerced through EntityElement#apply_to_element's :set branch.
    # Hand-built here to isolate that one case; the standard battery above
    # already exercises it against a real generated sequence.
    it "mutations_match_recompute names a plain entity-owned set whose after-state disagrees with the " \
       "recomputed value" do
      history = { bluebooks:       bluebooks_for(PROPERTIES_NESTED_PIECES),
                  mutation_traces: [
                    { verb:   "NestedPieces::Workspace.Board.Label",
                      before: { number: { value: 1 }, label: nil, cards: [] },
                      after:  { number: { value: 1 }, label: { value: "wrong" }, cards: [] },
                      args:   { label: "right" } }
                  ] }

      result = Hecks::Fuzzing::Properties.mutations_match_recompute(history)
      expect(result).to be_a(String)
      expect(result).to include("Label").and include("set")
    end

    it "mutations_match_recompute passes a plain entity-owned set correctly recomputed" do
      history = { bluebooks:       bluebooks_for(PROPERTIES_NESTED_PIECES),
                  mutation_traces: [
                    { verb:   "NestedPieces::Workspace.Board.Label",
                      before: { number: { value: 1 }, label: nil, cards: [] },
                      after:  { number: { value: 1 }, label: { value: "right" }, cards: [] },
                      args:   { label: "right" } }
                  ] }

      expect(Hecks::Fuzzing::Properties.mutations_match_recompute(history)).to be(true)
    end

    it "mutations_match_recompute starts from a command's declared default for an argument left out" do
      history = { bluebooks:       bluebooks_for(PROPERTIES_NESTED_PIECES),
                  mutation_traces: [
                    { verb:   "NestedPieces::Workspace.Board.Retitle",
                      before: { number: { value: 1 }, label: nil, cards: [] },
                      after:  { number: { value: 1 }, label: { value: "untitled" }, cards: [] },
                      args:   {} }
                  ] }

      expect(Hecks::Fuzzing::Properties.mutations_match_recompute(history)).to be(true)
    end

    it "mutations_match_recompute prefers an argument the caller named over the default" do
      history = { bluebooks:       bluebooks_for(PROPERTIES_NESTED_PIECES),
                  mutation_traces: [
                    { verb:   "NestedPieces::Workspace.Board.Retitle",
                      before: { number: { value: 1 }, label: nil, cards: [] },
                      after:  { number: { value: 1 }, label: { value: "untitled" }, cards: [] },
                      args:   { label: "mine" } }
                  ] }

      expect(Hecks::Fuzzing::Properties.mutations_match_recompute(history)).to include("Retitle").and include("mine")
    end

    it "guard_refusals_are_declared names a refusal quoting text no given/ensures on the command declares" do
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  refusals:  [{ verb: "Banking::Account.Credit", error: "Credit refused — a made up reason",
                              kind: "Hecks::Runtime::GivenNotMet" }] }

      result = Hecks::Fuzzing::Properties.guard_refusals_are_declared(history)
      expect(result).to be_a(String)
      expect(result).to include("a made up reason")
    end

    it "guard_refusals_are_declared passes a refusal quoting the command's own declared given through" do
      # "customer is active" (ADR 0025's named precondition, referenced
      # from Account.given) is a real entry in Credit.givens, which is
      # all this property reads. "the account is open" would not fit:
      # that's a lifecycle guard (`from: "open"`), raising
      # LifecycleRefused, never GivenNotMet.
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  refusals:  [{ verb: "Banking::Account.Credit", error: "Credit refused — customer is active",
                              kind: "Hecks::Runtime::GivenNotMet" }] }

      expect(Hecks::Fuzzing::Properties.guard_refusals_are_declared(history)).to be(true)
    end

    # A delegates_to door refuses with its target's own given, in the
    # door's name — Roster.Retire passes through to Member.Retire, so
    # "a front-row holder may not retire" is Retire's own given text.
    it "guard_refusals_are_declared follows a door's delegates_to to the guards that actually refused" do
      history = { bluebooks: bluebooks_for(File.join(ROOT_DIR, "examples/roster")),
                  refusals:  [{ verb:  "Roster::Roster.Retire",
                                error: "Retire refused — a front-row holder may not retire",
                                kind:  "Hecks::Runtime::GivenNotMet" }] }

      expect(Hecks::Fuzzing::Properties.guard_refusals_are_declared(history)).to be(true)

      history[:refusals].first[:error] = "Retire refused — a made up reason"
      expect(Hecks::Fuzzing::Properties.guard_refusals_are_declared(history)).to include("a made up reason")
    end

    it "guard_refusals_are_declared resolves a refusal against ITS OWN domain, not just the first-loaded one" do
      # A domain under fuzz commonly composes more than one bluebook
      # (Expression loads before Translation here). A genuine given
      # refusal from a non-first domain would misread as "no declared
      # command resolves that verb" if command_for_verb only consulted
      # whichever bluebook loaded first.
      bluebooks = bluebooks_for(PROPERTIES_GRAMMAR)
      # Expression loads first, Translation second, Governance last —
      # both hecksagons call attaches "Governance" (role is only
      # real access control once Governance can check it) from inside
      # their own blocks, so it attaches after either chapter.
      expect(bluebooks.keys).to eq(%w[Expression Translation Governance])

      history = { bluebooks: bluebooks,
                  refusals:  [{ verb:  "Translation::Map.Seal",
                                error: "Seal refused — an empty edge explains nothing",
                                kind:  "Hecks::Runtime::GivenNotMet" }] }

      expect(Hecks::Fuzzing::Properties.guard_refusals_are_declared(history)).to be(true)
    end

    it "guard_refusals_are_declared ignores a refusal sharing the same wording but a DIFFERENT raised class" do
      # LifecycleRefused/transition_blocked shares GivenNotMet's exact
      # "X refused — Y" shape (RefusalWording's own template) — a
      # refusal identified by string alone would misread this as an
      # undeclared guard; identified by `kind:`, it is skipped outright.
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  refusals:  [{ verb:  "Banking::Account.CloseAccount",
                                error: "CloseAccount refused — status is closed, and CloseAccount moves it only " \
                                       "from open, frozen",
                                kind:  "Hecks::Runtime::LifecycleRefused" }] }

      expect(Hecks::Fuzzing::Properties.guard_refusals_are_declared(history)).to be(true)
    end

    it "lifecycle_guard_and_given_violations_are_refused names a step the guard should have refused but didn't" do
      history = { guard_checks: [
        { verb: "Banking::Account.Debit", recomputed_refused: true, recomputed_kind: "Hecks::Runtime::GivenNotMet",
          actual_refused: false, actual_kind: nil }
      ] }

      result = Hecks::Fuzzing::Properties.lifecycle_guard_and_given_violations_are_refused(history)
      expect(result).to be_a(String)
      expect(result).to include("Banking::Account.Debit").and include("refused").and include("admitted")
    end

    it "lifecycle_guard_and_given_violations_are_refused names a step the guard refused but shouldn't have" do
      history = { guard_checks: [
        { verb: "Banking::Account.Credit", recomputed_refused: false, recomputed_kind: nil,
          actual_refused: true, actual_kind: "Hecks::Runtime::LifecycleRefused" }
      ] }

      result = Hecks::Fuzzing::Properties.lifecycle_guard_and_given_violations_are_refused(history)
      expect(result).to be_a(String)
      expect(result).to include("Banking::Account.Credit")
    end

    it "lifecycle_guard_and_given_violations_are_refused passes when the recomputed and actual verdicts agree" do
      history = { guard_checks: [
        { verb: "Banking::Account.Debit", recomputed_refused: false, recomputed_kind: nil,
          actual_refused: false, actual_kind: nil },
        { verb: "Banking::Account.CloseAccount", recomputed_refused: true, recomputed_kind: "Hecks::Runtime::LifecycleRefused",
          actual_refused: true, actual_kind: "Hecks::Runtime::LifecycleRefused" }
      ] }

      expect(Hecks::Fuzzing::Properties.lifecycle_guard_and_given_violations_are_refused(history)).to be(true)
    end

    it "sagas_rehydrate_cleanly names a live instance holding a state its process manager never declares" do
      history = { bluebook:       bluebook_for(PROPERTIES_BANKING),
                  saga_instances: { "Onboarding" => { "corr-1" => { state: "teleported", memory: { a: 1 } } } } }

      result = Hecks::Fuzzing::Properties.sagas_rehydrate_cleanly(history)
      expect(result).to be_a(String)
      expect(result).to include("teleported")
    end

    it "sagas_rehydrate_cleanly names a memory that does not survive its own checkpoint round-trip" do
      # A bare Symbol leaf — `deep_copy`'s own JSON round-trip (the exact
      # write/read a real `save_saga`/`each_saga` adapter performs) reads
      # a Symbol value back as a String, so this is corruption the
      # durable path would introduce on a real restart, not a
      # hypothetical one.
      history = { bluebook:       bluebook_for(PROPERTIES_BANKING),
                  saga_instances: { "Onboarding" => { "corr-1" => { state: "screening", memory: { kind: :wire } } } } }

      result = Hecks::Fuzzing::Properties.sagas_rehydrate_cleanly(history)
      expect(result).to be_a(String)
      expect(result).to include("does not survive its own checkpoint round-trip")
    end

    it "sagas_rehydrate_cleanly passes a genuinely declared state and round-trip-safe memory through" do
      history = { bluebook:       bluebook_for(PROPERTIES_BANKING),
                  saga_instances: { "Onboarding" => { "corr-1" =>
                                                                  { state:  "screening",
                                                                    memory: { customer:  "delta juliet",
                                                                              reference: { value: "corr-1" } } } } } }

      expect(Hecks::Fuzzing::Properties.sagas_rehydrate_cleanly(history)).to be(true)
    end

    it "fanout_dispatches_once_per_matching_row names a row the reaction log missed" do
      history = { fan_outs: [{ policy: "ReviewOnFlag", on: "Flagged",
                              expected_row_ids: ["a1", "a2"], actual_row_ids: ["a1"] }] }

      result = Hecks::Fuzzing::Properties.fanout_dispatches_once_per_matching_row(history)
      expect(result).to be_a(String)
      expect(result).to include('["a1", "a2"]').and include('["a1"]')
    end

    it "fanout_dispatches_once_per_matching_row names a dispatch that fired despite a failing where" do
      history = { fan_outs: [{ policy: "ReviewOnFlag", on: "Flagged",
                              expected_row_ids: nil, actual_row_ids: ["a1"] }] }

      result = Hecks::Fuzzing::Properties.fanout_dispatches_once_per_matching_row(history)
      expect(result).to be_a(String)
      expect(result).to include("where did not hold")
    end

    it "fanout_dispatches_once_per_matching_row passes an exact match, and a guarded no-op, through" do
      history = { fan_outs: [
        { policy: "ReviewOnFlag", on: "Flagged", expected_row_ids: ["a1", "a2"], actual_row_ids: ["a2", "a1"] },
        { policy: "ReviewOnFlag", on: "Flagged", expected_row_ids: nil, actual_row_ids: [] }
      ] }

      expect(Hecks::Fuzzing::Properties.fanout_dispatches_once_per_matching_row(history)).to be(true)
    end

    it "aggregation_matches_recompute names a count that disagrees with the recomputed eligible rows" do
      instances = {
        "Banking::CardPayment#p1" => { account: "acct-1", status: "disputed" },
        "Banking::CardPayment#p2" => { account: "acct-1", status: "disputed" },
        "Banking::CardPayment#p3" => { account: "acct-1", status: "authorized" }
      }
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  queries:  [{ query: "Banking.disputed_payment_count", args: { account: "acct-1" },
                             instances_at: instances, rows: [{ account: {}, card_payments: 99 }] }] }

      result = Hecks::Fuzzing::Properties.aggregation_matches_recompute(history)
      expect(result).to be_a(String)
      expect(result).to include("99").and include("2")
    end

    it "aggregation_matches_recompute passes a count that matches the recomputed eligible rows" do
      instances = {
        "Banking::CardPayment#p1" => { account: "acct-1", status: "disputed" },
        "Banking::CardPayment#p2" => { account: "acct-1", status: "disputed" },
        "Banking::CardPayment#p3" => { account: "acct-1", status: "authorized" },
        "Banking::CardPayment#p4" => { account: "acct-2", status: "disputed" }
      }
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  queries:  [{ query: "Banking.disputed_payment_count", args: { account: "acct-1" },
                             instances_at: instances, rows: [{ account: {}, card_payments: 2 }] }] }

      expect(Hecks::Fuzzing::Properties.aggregation_matches_recompute(history)).to be(true)
    end

    it "aggregation_matches_recompute passes a median matching the interpreter's own even/odd convention" do
      instances = {
        "Banking::CardPayment#p1" => { account: "acct-1", status: "disputed", amount: { cents: 100 } },
        "Banking::CardPayment#p2" => { account: "acct-1", status: "disputed", amount: { cents: 300 } }
      }
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  queries:  [{ query: "Banking.disputed_payment_median", args: { account: "acct-1" },
                             instances_at: instances, rows: [{ account: {}, card_payments: 200.0 }] }] }

      expect(Hecks::Fuzzing::Properties.aggregation_matches_recompute(history)).to be(true)
    end

    it "stored_records_satisfy_declared_invariants names a stored balance that violates Account's own invariant" do
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  instances: { "Banking::Account#a1" => { balance: { cents: -500, currency: "USD" } } } }

      result = Hecks::Fuzzing::Properties.stored_records_satisfy_declared_invariants(history)
      expect(result).to be_a(String)
      expect(result).to include("Banking::Account#a1").and include("the balance never goes negative")
    end

    it "stored_records_satisfy_declared_invariants passes a stored balance that holds the invariant" do
      history = { bluebooks: bluebooks_for(PROPERTIES_BANKING),
                  instances: { "Banking::Account#a1" => { balance: { cents: 500, currency: "USD" } } } }

      expect(Hecks::Fuzzing::Properties.stored_records_satisfy_declared_invariants(history)).to be(true)
    end

    # AccountsByKind — real corpus, group_by :kind, :number, rootless. The
    # instances here supply :kind/:number as bare strings rather than real
    # Kind{name}/Number{value} VOs — Value.materialize_unwrapped is a no-op
    # on an already-bare String either way (the `when self` single-VO-
    # unwrap branch only ever fires on a real Value instance), so this
    # exercises the grouping/nesting recomputation itself without needing
    # to hand-construct real Value objects for a hand-built history — the
    # single-VO unwrap is ReadModelInterpreter's own spec's job, not this
    # oracle's.
    it "group_by_matches_recompute names a grouping that disagrees with the recomputed nesting" do
      instances = {
        "Banking::Account#a1" => { kind: "current", number: "a1", daily_limit: { cents: 0 } },
        "Banking::Account#a2" => { kind: "savings", number: "a2", daily_limit: { cents: 0 } },
        "Banking::Account#a3" => { kind: "current", number: "a3", daily_limit: { cents: 0 } }
      }
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  queries:  [{ query: "Banking.accounts_by_kind", args: {}, instances_at: instances,
                             rows: [{ accounts: {} }] }] }

      result = Hecks::Fuzzing::Properties.group_by_matches_recompute(history)
      expect(result).to be_a(String)
      expect(result).to include("Banking.accounts_by_kind").and include("3 eligible row(s)")
    end

    it "group_by_matches_recompute passes a grouping that matches the recomputed nesting" do
      instances = {
        "Banking::Account#a1" => { kind: "current", number: "a1", daily_limit: { cents: 0 } },
        "Banking::Account#a2" => { kind: "savings", number: "a2", daily_limit: { cents: 0 } }
      }
      history = { bluebook: bluebook_for(PROPERTIES_BANKING),
                  queries:  [{ query: "Banking.accounts_by_kind", args: {}, instances_at: instances,
                             rows: [{ accounts: {
                               "current" => { "a1" => { daily_limit: { cents: 0 }, id: "a1" } },
                               "savings" => { "a2" => { daily_limit: { cents: 0 }, id: "a2" } }
                             } }] }] }

      expect(Hecks::Fuzzing::Properties.group_by_matches_recompute(history)).to be(true)
    end

    # ADR 0061, decision D1: a group_by leaf holds one row. `PartsByBin`
    # groups by `bin` alone, so two parts in one bin must refuse; the oracle
    # finds the shared key path from the rows, never from a nesting.
    it "group_by_matches_recompute names an answer given where two eligible rows share a key path" do
      history = { bluebook: bluebook_for(PROPERTIES_GROUP_BY_COLLISION),
                  queries:  [{ query: "GroupByCollisionFixture.PartsByBin", args: {}, instances_at: colliding_parts,
                             rows: [{ parts: { "b1" => { ref: "p1", id: "p1" } } }] }] }

      result = Hecks::Fuzzing::Properties.group_by_matches_recompute(history)
      expect(result).to be_a(String)
      expect(result).to include("GroupByCollisionFixture.PartsByBin").and include("so the ask must refuse")
    end

    it "group_by_matches_recompute passes a refusal where two eligible rows share a key path" do
      history = { bluebook: bluebook_for(PROPERTIES_GROUP_BY_COLLISION),
                  queries:  [{ query: "GroupByCollisionFixture.PartsByBin", args: {}, instances_at: colliding_parts,
                             rows: nil, error: "PartsByBin groups by bin, but rows ..." }] }

      expect(Hecks::Fuzzing::Properties.group_by_matches_recompute(history)).to be(true)
    end

    it "group_by_matches_recompute expects an answer when the key path covers the identity" do
      history = { bluebook: bluebook_for(PROPERTIES_GROUP_BY_COLLISION),
                  queries:  [{ query: "GroupByCollisionFixture.PartsByBinAndRef", args: {}, instances_at: colliding_parts,
                             rows: [{ parts: { "b1" => { "p1" => { id: "p1" }, "p2" => { id: "p2" } },
                                               "b2" => { "p3" => { id: "p3" } } } }] }] }

      expect(Hecks::Fuzzing::Properties.group_by_matches_recompute(history)).to be(true)
    end
  end
end
