require "spec_helper"
require "hecks/fuzzing"

# Declared properties over generated histories. Two directions: the
# standard battery holds over real generated sequences (below), and
# each property fires against a hand-built history that violates it —
# a property that can never fail is decoration.
RSpec.describe "Hecks::Fuzzing::Properties", :aggregate_failures do
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

  PROPERTIES_GIVEN_NOT_MET = "Hecks::Runtime::GivenNotMet".freeze
  PROPERTIES_LIFECYCLE_REFUSED = "Hecks::Runtime::LifecycleRefused".freeze

  # `adapter:` only picks replay's repository; generation always stays Memory (isolated_boot.rb).
  def generated_history(domain, seed, adapter: :memory)
    steps = Hecks::Fuzzing::SequenceGenerator.generate(domain, seed: seed, steps: 25)
    Hecks::Fuzzing::Replay.call(domain, steps, adapter: adapter)
  end

  # Every `domain seed N — property: result` line for a battery property that did not answer true.
  def battery_failures(domain, seed_count, adapter: :memory)
    label = adapter == :memory ? "" : " (#{adapter})"
    (1..seed_count).flat_map do |seed|
      results = Hecks::Fuzzing::Properties.check(generated_history(domain, seed, adapter: adapter))
      results.reject { |_, result| result == true }
             .map { |property, result| "#{domain} seed #{seed}#{label} — #{property}: #{result}" }
    end
  end

  # Every `domain seed N: result` line for a generated sequence whose replay was not deterministic.
  def determinism_failures(domain, seed_count)
    (1..seed_count).filter_map do |seed|
      steps = Hecks::Fuzzing::SequenceGenerator.generate(domain, seed: seed, steps: 25)
      result = Hecks::Fuzzing::Properties.replay_is_deterministic(domain, steps)
      "#{domain} seed #{seed}: #{result}" unless result == true
    end
  end

  def finding(property, history) = Hecks::Fuzzing::Properties.public_send(property, history)

  describe "the standard battery, over real generated sequences" do
    [[PROPERTIES_PIZZAS, 5], [PROPERTIES_BANKING, 5], [PROPERTIES_ENTITY_MUTATIONS, 10],
     [PROPERTIES_NESTED_PIECES, 40]].each do |domain, seed_count|
      it "holds for #{File.basename(domain)} across #{seed_count} seeds" do
        expect(battery_failures(domain, seed_count)).to be_empty
      end

      it "stays deterministic for #{File.basename(domain)} across #{seed_count} seeds" do
        expect(determinism_failures(domain, seed_count)).to be_empty
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
        expect(battery_failures(domain, seed_count, adapter: :sqlite)).to be_empty
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

    # A query ask as `Replay` records it, for the Pizzas::Order.Expensive query.
    def query_ask(**fields) = { query: "Pizzas::Order.Expensive", args: {} }.merge(fields)

    # Asks the two engines agree on: the same rows, a refusal from both, and a read-model ask.
    def agreeing_asks
      [query_ask(rows: [{ id: "M" }], reference_rows: [{ id: "M" }]),
       # Both engines refused, in agreement — not a finding, modeled with
       # both error: and reference_error: present (the shape Replay
       # produces when both engines raise independently).
       query_ask(error: "refused", reference_error: "refused"),
       { query: "Pizzas.some_read_model", args: {}, rows: [] }]
    end

    # A saga advance of Banking's Settlement process manager, as recorded in `history[:sagas]`.
    def saga_advance(on, to)
      { process_manager: "Settlement", on: on, instance: "x", advanced: true, from: "requested", to: to }
    end

    # Four active ATMCards with distinct fees, and the row the query would answer for card `n`.
    def atm_cards
      (1..4).to_h { |n| ["Banking::ATMCard#s#{n}", { status: "active", daily_fee: { amount: n.to_f }, serial: { value: "s#{n}" } }] }
    end

    def atm_row(num) = { id: "s#{num}", status: "active", daily_fee: { amount: num.to_f }, serial: { value: "s#{num}" } }

    def by_fee_history(rows)
      { bluebooks: bluebooks_for(PROPERTIES_BANKING),
        queries:   [{ query: "Banking::ATMCard.ByFee", args: {}, instances_at: atm_cards, rows: rows }] }
    end

    # A Client -> Engagement -> Proposal chain whose client has the given status.
    def hop_chain_history(client_status)
      instances = {
        "HopChain::Client#juliet"      => { name: { value: "juliet" }, status: client_status },
        "HopChain::Engagement#charlie" => { client: "juliet", reference: { value: "charlie" }, stage: "started" },
        "HopChain::Proposal#p1"        => { engagement: "charlie", number: { value: "p1" }, status: "drafted" }
      }
      row = { id: "p1", engagement: "charlie", number: { value: "p1" }, status: "drafted" }
      { bluebooks: bluebooks_for(PROPERTIES_FIXTURES),
        queries:   [{ query: "HopChain::Proposal.PricedAboveViaEngagement", args: {}, instances_at: instances, rows: [row] }] }
    end

    def rented_box(branch, number)
      { id: "#{branch}:#{number}", branch_code: { value: branch }, box_number: { value: number }, status: "rented" }
    end

    # Asks of Banking::SafeDepositBox.Rented, each given as its own `args:` plus `rows:` or `error:`.
    def rented_history(*asks)
      { bluebooks: bluebooks_for(PROPERTIES_BANKING),
        queries:   asks.map { |ask| { query: "Banking::SafeDepositBox.Rented" }.merge(ask) } }
    end

    def tenant_wording_error
      "Rented declares authorize with tenant: branch_code — pass branch_code: to name " \
        "which branch_code this ask is scoped to"
    end

    def mutation_trace(verb, before, after, args) = { verb: verb, before: before, after: after, args: args }

    def trace_history(domain, *traces) = { bluebooks: bluebooks_for(domain), mutation_traces: traces }

    # A TaggedList's state: its label, its count and, when it has them, its tags.
    def list_state(count, tags = nil)
      { label: { value: "l1" }, count: { value: count } }.merge(tags ? { tags: tags } : {})
    end

    def list_args(**extra) = { name: { value: "b1" }, label: { value: "l1" } }.merge(extra)

    def tag_trace(verb, before_tags, after_tags, args)
      mutation_trace("EntityListMutations::Board.TaggedList.#{verb}", list_state(0, before_tags), list_state(0, after_tags), args)
    end

    # The four entity-owned operations, each recomputed correctly.
    def correct_list_traces
      tag = { key: "k1", value: "v1" }
      [tag_trace("AddTag", [], [tag], list_args(key: "k1", value: "v1")),
       tag_trace("RemoveTag", [tag], [], list_args(tag: { "key" => "k1", "value" => "v1" })),
       mutation_trace("EntityListMutations::Board.TaggedList.Scale", list_state(4), list_state(12), list_args(factor: 3)),
       mutation_trace("EntityListMutations::Board.TaggedList.Clamp", list_state(15), list_state(10), list_args)]
    end

    def board_state(label, cards = []) = { number: { value: 1 }, label: label, cards: cards }

    def board_trace(verb, after_label, args, after_cards: [])
      mutation_trace("NestedPieces::Workspace.Board.#{verb}", board_state(nil), board_state(after_label, after_cards), args)
    end

    def refusal_history(bluebooks, verb, error, kind = PROPERTIES_GIVEN_NOT_MET)
      { bluebooks: bluebooks, refusals: [{ verb: verb, error: error, kind: kind }] }
    end

    # A guard check whose recomputed and actual verdicts are the given refusal kinds (nil: admitted).
    def guard_check(verb, recomputed_kind, actual_kind)
      { verb: verb, recomputed_refused: !recomputed_kind.nil?, recomputed_kind: recomputed_kind,
        actual_refused: !actual_kind.nil?, actual_kind: actual_kind }
    end

    def saga_history(state, memory)
      { bluebook:       bluebook_for(PROPERTIES_BANKING),
        saga_instances: { "Onboarding" => { "corr-1" => { state: state, memory: memory } } } }
    end

    def fan_out(expected, actual)
      { policy: "ReviewOnFlag", on: "Flagged", expected_row_ids: expected, actual_row_ids: actual }
    end

    def card_payment(num, account, status, **extra)
      ["Banking::CardPayment#p#{num}", { account: account, status: status }.merge(extra)]
    end

    def payment_history(query, instances, rows)
      { bluebook: bluebook_for(PROPERTIES_BANKING),
        queries:  [{ query: query, args: { account: "acct-1" }, instances_at: instances, rows: rows }] }
    end

    def account_history(cents)
      { bluebooks: bluebooks_for(PROPERTIES_BANKING),
        instances: { "Banking::Account#a1" => { balance: { cents: cents, currency: "USD" } } } }
    end

    # Accounts a1, a2, ... of the given kinds, with bare-string `kind`/`number`.
    def account_instances(*kinds)
      kinds.each_with_index.to_h do |kind, index|
        ["Banking::Account#a#{index + 1}", { kind: kind, number: "a#{index + 1}", daily_limit: { cents: 0 } }]
      end
    end

    def accounts_by_kind_history(instances, rows)
      { bluebook: bluebook_for(PROPERTIES_BANKING),
        queries:  [{ query: "Banking.accounts_by_kind", args: {}, instances_at: instances, rows: rows }] }
    end

    def parts_history(query, **fields)
      { bluebook: bluebook_for(PROPERTIES_GROUP_BY_COLLISION),
        queries:  [{ query: query, args: {}, instances_at: colliding_parts }.merge(fields)] }
    end

    PROPERTIES_WRONG_SAGA_BINDING = { saga_dispatches: [
      { process_manager: "Settlement", instance: "ref-1", dispatch: "Account::Credit", on: "AccountDebited",
        correlation_head: :reference, event_payload: { source: "a1", destination: "a2", amount: 500 },
        memory: { destination: "a2" }, with_spec: { number: :destination, amount: :amount },
        args: { number: "WRONG", amount: 500 } }
    ] }.freeze

    PROPERTIES_WRONG_POLICY_BINDING = { policy_dispatches: [
      { policy: "NotifyOnDebit", on: "AccountDebited", payload: { account: "a1", amount: 500 },
        with_spec: { account_ref: :account }, args: { account_ref: "WRONG" } }
    ] }.freeze

    # All four SagaInterpreter#dispatch_args branches, in one entry —
    # literal (`narrative:`), correlation-head (`transfer:`),
    # current-event-payload (`amount:`), and saga-memory-fallback
    # (`number:`, absent from event_payload, present only in memory) —
    # plus a policy trigger's own 2-branch resolution (literal, payload).
    PROPERTIES_CORRECT_BINDINGS = {
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
    }.freeze

    it "lifecycle_values_are_declared names an instance holding an undeclared state" do
      history = { bluebook:  bluebook_for(PROPERTIES_PIZZAS),
                  instances: { "Pizzas::Order#p1" => { status: "teleported" } } }

      expect(finding(:lifecycle_values_are_declared, history)).to be_a(String).and include("teleported")
    end

    it "lifecycle_values_are_declared passes a genuinely declared state through" do
      history = { bluebook:  bluebook_for(PROPERTIES_PIZZAS),
                  instances: { "Pizzas::Order#p1" => { status: "available" } } }

      expect(finding(:lifecycle_values_are_declared, history)).to be(true)
    end

    it "saga_advances_follow_declared_handlers names an advance no handler declares" do
      history = { bluebook: bluebook_for(PROPERTIES_BANKING), sagas: [saga_advance("Invented", "nowhere_declared")] }

      expect(finding(:saga_advances_follow_declared_handlers, history)).to be_a(String).and include("nowhere_declared")
    end

    it "saga_advances_follow_declared_handlers passes a genuinely declared edge through" do
      history = { bluebook: bluebook_for(PROPERTIES_BANKING), sagas: [saga_advance("TransferRequested", "requested")] }

      expect(finding(:saga_advances_follow_declared_handlers, history)).to be(true)
    end

    it "query_answers_match_reference names a native answer the reference interpreter disputes" do
      history = { queries: [query_ask(rows: [{ id: "Margherita" }], reference_rows: [])] }

      expect(finding(:query_answers_match_reference, history)).to be_a(String).and include("Pizzas::Order.Expensive", "natively")
    end

    it "query_answers_match_reference passes agreement, refusals, and read-model asks through" do
      expect(finding(:query_answers_match_reference, { queries: agreeing_asks })).to be(true)
    end

    # Pins a refusal-shaped divergence — one engine refusing while the
    # other answers — as something the property must be able to name,
    # not something a shared rescue silently discards.
    it "query_answers_match_reference names a refusal-shaped divergence — one engine refused, the other didn't" do
      history = { queries: [query_ask(rows: [{ id: "Margherita" }], reference_error: "reference refused")] }

      expect(finding(:query_answers_match_reference, history)).to be_a(String)
        .and include("Pizzas::Order.Expensive", "divergence")
    end

    it "query_answers_match_reference names the reverse refusal-shaped divergence too — reference refused, native didn't" do
      history = { queries: [query_ask(error: "native refused", reference_rows: [{ id: "Margherita" }])] }

      expect(finding(:query_answers_match_reference, history)).to be_a(String)
        .and include("Pizzas::Order.Expensive", "divergence")
    end

    it "replay_is_deterministic names a real divergence — a genuinely different step count" do
      # Not a manufactured non-determinism (the runtime does not have
      # one to hand) — a wrong claim that two different step lists are
      # "the same replay" is exactly what this property exists to catch,
      # so this proves the comparison itself is sensitive to real drift.
      create = { "verb" => "Pizzas::Order.CreatePizza",
                 "args" => { "name"  => { "value" => "X" },
                             "pizza" => { "price_cents" => { "cents" => 100 }, "size" => { "value" => "small" } } } }
      first, second = [[], [create]].map { |steps| Hecks::Fuzzing::Replay.call(PROPERTIES_PIZZAS, steps).except(:bluebook, :bluebooks) }

      expect(first).not_to eq(second)
    end

    # ATMCard.ByFee — real corpus, `order_by :daily_fee; limit 3; offset
    # 1`. Four active cards, distinct fees; the true offset-1/limit-3 page
    # is cards 2-4.
    it "paging_offset_partitions_correctly names an answer that disagrees with the recomputed page" do
      history = by_fee_history([atm_row(1)])

      expect(finding(:paging_offset_partitions_correctly, history)).to be_a(String)
        .and include("Banking::ATMCard.ByFee", "4 eligible row(s)")
    end

    it "paging_offset_partitions_correctly passes an answer that skips before it takes" do
      history = by_fee_history((2..4).map { |num| atm_row(num) })

      expect(finding(:paging_offset_partitions_correctly, history)).to be(true)
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
      expect(finding(:paging_offset_partitions_correctly, hop_chain_history("active"))).to be(true)
    end

    it "paging_offset_partitions_correctly still names an answer whose hop's far end does not actually hold" do
      result = finding(:paging_offset_partitions_correctly, hop_chain_history("churned"))

      expect(result).to be_a(String).and include("HopChain::Proposal.PricedAboveViaEngagement", "0 eligible row(s)")
    end

    # SafeDepositBox.Rented — real corpus, `where(status: "rented"); order_by
    # :branch_code; authorize :vault_access, tenant: :branch_code`.
    it "authorize_scopes_or_refuses names a successful answer whose tenant field disagrees with the given arg" do
      history = rented_history(args: { branch_code: "DOWNTOWN" }, rows: [rented_box("UPTOWN", 1)])

      expect(finding(:authorize_scopes_or_refuses, history)).to be_a(String)
        .and include("Banking::SafeDepositBox.Rented", "UPTOWN")
    end

    it "authorize_scopes_or_refuses names a successful answer with no tenant arg given at all" do
      history = rented_history(args: {}, rows: [rented_box("DOWNTOWN", 12)])

      expect(finding(:authorize_scopes_or_refuses, history)).to be_a(String).and include("Banking::SafeDepositBox.Rented")
    end

    it "authorize_scopes_or_refuses names a refusal with no tenant given that used the wrong wording" do
      history = rented_history(args: {}, error: "a made up refusal")

      expect(finding(:authorize_scopes_or_refuses, history)).to be_a(String)
        .and include("Banking::SafeDepositBox.Rented", "a made up refusal")
    end

    it "authorize_scopes_or_refuses passes a successful answer whose tenant field matches the given arg, " \
       "and a correctly-worded refusal with no tenant" do
      history = rented_history({ args: { branch_code: "DOWNTOWN" }, rows: [rented_box("DOWNTOWN", 12)] },
                               { args: {}, error: tenant_wording_error })

      expect(finding(:authorize_scopes_or_refuses, history)).to be(true)
    end

    it "dispatch_binding_fidelity names a saga dispatch bound to the wrong value" do
      result = finding(:dispatch_binding_fidelity, PROPERTIES_WRONG_SAGA_BINDING)

      expect(result).to be_a(String).and include("Settlement", "Account::Credit", "WRONG")
    end

    it "dispatch_binding_fidelity names a policy trigger bound to the wrong value" do
      result = finding(:dispatch_binding_fidelity, PROPERTIES_WRONG_POLICY_BINDING)

      expect(result).to be_a(String).and include("NotifyOnDebit", "WRONG")
    end

    it "dispatch_binding_fidelity passes saga and policy dispatches correctly bound on every resolution branch" do
      expect(finding(:dispatch_binding_fidelity, PROPERTIES_CORRECT_BINDINGS)).to be(true)
    end

    it "mutations_match_recompute names an append whose after-state disagrees with the recomputed element" do
      trace = tag_trace("AddTag", [], [], list_args(key: "k1", value: "v1"))

      result = finding(:mutations_match_recompute, trace_history(PROPERTIES_ENTITY_MUTATIONS, trace))
      expect(result).to be_a(String).and include("AddTag", "append")
    end

    it "mutations_match_recompute names a clamp whose after-state disagrees with the recomputed bound" do
      trace = mutation_trace("EntityListMutations::Board.TaggedList.Clamp", list_state(15), list_state(15), list_args)

      result = finding(:mutations_match_recompute, trace_history(PROPERTIES_ENTITY_MUTATIONS, trace))
      expect(result).to be_a(String).and include("Clamp", "clamp")
    end

    it "mutations_match_recompute passes append/remove/multiply/clamp all correctly recomputed" do
      history = trace_history(PROPERTIES_ENTITY_MUTATIONS, *correct_list_traces)

      expect(finding(:mutations_match_recompute, history)).to be(true)
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
      # nil, since Card.note (optional: true) isn't in
      # AddCard's append mapping, but a freshly appended
      # Card still carries the key, nil-valued regardless.
      trace = board_trace("AddCard", nil, { number: { value: 1 }, sequence: 821 },
                          after_cards: [{ sequence: { value: 821 }, note: nil }])

      expect(finding(:mutations_match_recompute, trace_history(PROPERTIES_NESTED_PIECES, trace))).to be(true)
    end

    # Same before/args as the passing VO-typed-append example above — the
    # identical scalar 821 still coerces to { value: 821 } — except this
    # `after` claims { value: 999 } landed instead, a real mismatch
    # unrelated to VO-wrapping. Proves the comparison is coerced-against-
    # coerced, not skipping the field (which would miss exactly this).
    it "mutations_match_recompute still names a genuinely wrong VO-typed append, not merely a coercion artifact" do
      trace = board_trace("AddCard", nil, { number: { value: 1 }, sequence: 821 },
                          after_cards: [{ sequence: { value: 999 } }])

      result = finding(:mutations_match_recompute, trace_history(PROPERTIES_NESTED_PIECES, trace))
      expect(result).to be_a(String).and include("AddCard", "append")
    end

    # NestedPieces::Workspace.Board.Label (`sets :label`, no append/remove/
    # multiply/clamp) is the real corpus site for an entity-owned plain
    # set, coerced through EntityElement#apply_to_element's :set branch.
    # Hand-built here to isolate that one case; the standard battery above
    # already exercises it against a real generated sequence.
    it "mutations_match_recompute names a plain entity-owned set whose after-state disagrees with the " \
       "recomputed value" do
      trace = board_trace("Label", { value: "wrong" }, { label: "right" })

      result = finding(:mutations_match_recompute, trace_history(PROPERTIES_NESTED_PIECES, trace))
      expect(result).to be_a(String).and include("Label", "set")
    end

    it "mutations_match_recompute passes a plain entity-owned set correctly recomputed" do
      trace = board_trace("Label", { value: "right" }, { label: "right" })

      expect(finding(:mutations_match_recompute, trace_history(PROPERTIES_NESTED_PIECES, trace))).to be(true)
    end

    it "mutations_match_recompute starts from a command's declared default for an argument left out" do
      trace = board_trace("Retitle", { value: "untitled" }, {})

      expect(finding(:mutations_match_recompute, trace_history(PROPERTIES_NESTED_PIECES, trace))).to be(true)
    end

    it "mutations_match_recompute prefers an argument the caller named over the default" do
      trace = board_trace("Retitle", { value: "untitled" }, { label: "mine" })

      result = finding(:mutations_match_recompute, trace_history(PROPERTIES_NESTED_PIECES, trace))
      expect(result).to include("Retitle", "mine")
    end

    it "guard_refusals_are_declared names a refusal quoting text no given/ensures on the command declares" do
      history = refusal_history(bluebooks_for(PROPERTIES_BANKING), "Banking::Account.Credit", "Credit refused — a made up reason")

      expect(finding(:guard_refusals_are_declared, history)).to be_a(String).and include("a made up reason")
    end

    it "guard_refusals_are_declared passes a refusal quoting the command's own declared given through" do
      # "customer is active" (ADR 0025's named precondition, referenced
      # from Account.given) is a real entry in Credit.givens, which is
      # all this property reads. "the account is open" would not fit:
      # that's a lifecycle guard (`from: "open"`), raising
      # LifecycleRefused, never GivenNotMet.
      history = refusal_history(bluebooks_for(PROPERTIES_BANKING), "Banking::Account.Credit",
                                "Credit refused — customer is active")

      expect(finding(:guard_refusals_are_declared, history)).to be(true)
    end

    # A delegates_to entry point refuses with its target's own given, in the
    # entry point's name — Roster.Retire passes through to Member.Retire, so
    # "a front-row holder may not retire" is Retire's own given text.
    it "guard_refusals_are_declared follows an entry point's delegates_to to the guards that actually refused" do
      history = refusal_history(bluebooks_for(File.join(ROOT_DIR, "examples/roster")), "Roster::Roster.Retire",
                                "Retire refused — a front-row holder may not retire")

      expect(finding(:guard_refusals_are_declared, history)).to be(true)

      history[:refusals].first[:error] = "Retire refused — a made up reason"
      expect(finding(:guard_refusals_are_declared, history)).to include("a made up reason")
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

      history = refusal_history(bluebooks, "Translation::Map.Seal", "Seal refused — an empty edge explains nothing")
      expect(finding(:guard_refusals_are_declared, history)).to be(true)
    end

    it "guard_refusals_are_declared ignores a refusal sharing the same wording but a DIFFERENT raised class" do
      # LifecycleRefused/transition_blocked shares GivenNotMet's exact
      # "X refused — Y" shape (RefusalWording's own template) — a
      # refusal identified by string alone would misread this as an
      # undeclared guard; identified by `kind:`, it is skipped outright.
      error = "CloseAccount refused — status is closed, and CloseAccount moves it only from open, frozen"
      history = refusal_history(bluebooks_for(PROPERTIES_BANKING), "Banking::Account.CloseAccount", error,
                                PROPERTIES_LIFECYCLE_REFUSED)

      expect(finding(:guard_refusals_are_declared, history)).to be(true)
    end

    it "lifecycle_guard_and_given_violations_are_refused names a step the guard should have refused but didn't" do
      history = { guard_checks: [guard_check("Banking::Account.Debit", PROPERTIES_GIVEN_NOT_MET, nil)] }

      result = finding(:lifecycle_guard_and_given_violations_are_refused, history)
      expect(result).to be_a(String).and include("Banking::Account.Debit", "refused", "admitted")
    end

    it "lifecycle_guard_and_given_violations_are_refused names a step the guard refused but shouldn't have" do
      history = { guard_checks: [guard_check("Banking::Account.Credit", nil, PROPERTIES_LIFECYCLE_REFUSED)] }

      result = finding(:lifecycle_guard_and_given_violations_are_refused, history)
      expect(result).to be_a(String).and include("Banking::Account.Credit")
    end

    it "lifecycle_guard_and_given_violations_are_refused passes when the recomputed and actual verdicts agree" do
      history = { guard_checks: [
        guard_check("Banking::Account.Debit", nil, nil),
        guard_check("Banking::Account.CloseAccount", PROPERTIES_LIFECYCLE_REFUSED, PROPERTIES_LIFECYCLE_REFUSED)
      ] }

      expect(finding(:lifecycle_guard_and_given_violations_are_refused, history)).to be(true)
    end

    it "sagas_rehydrate_cleanly names a live instance holding a state its process manager never declares" do
      result = finding(:sagas_rehydrate_cleanly, saga_history("teleported", { a: 1 }))

      expect(result).to be_a(String).and include("teleported")
    end

    it "sagas_rehydrate_cleanly names a memory that does not survive its own checkpoint round-trip" do
      # A bare Symbol leaf — `deep_copy`'s own JSON round-trip (the exact
      # write/read a real `save_saga`/`each_saga` adapter performs) reads
      # a Symbol value back as a String, so this is corruption the
      # durable path would introduce on a real restart, not a
      # hypothetical one.
      result = finding(:sagas_rehydrate_cleanly, saga_history("screening", { kind: :wire }))

      expect(result).to be_a(String).and include("does not survive its own checkpoint round-trip")
    end

    it "sagas_rehydrate_cleanly passes a genuinely declared state and round-trip-safe memory through" do
      memory = { customer: "delta juliet", reference: { value: "corr-1" } }

      expect(finding(:sagas_rehydrate_cleanly, saga_history("screening", memory))).to be(true)
    end

    it "fanout_dispatches_once_per_matching_row names a row the reaction log missed" do
      history = { fan_outs: [fan_out(["a1", "a2"], ["a1"])] }

      expect(finding(:fanout_dispatches_once_per_matching_row, history)).to be_a(String).and include('["a1", "a2"]', '["a1"]')
    end

    it "fanout_dispatches_once_per_matching_row names a dispatch that fired despite a failing where" do
      history = { fan_outs: [fan_out(nil, ["a1"])] }

      expect(finding(:fanout_dispatches_once_per_matching_row, history)).to be_a(String).and include("where did not hold")
    end

    it "fanout_dispatches_once_per_matching_row passes an exact match, and a guarded no-op, through" do
      history = { fan_outs: [fan_out(["a1", "a2"], ["a2", "a1"]), fan_out(nil, [])] }

      expect(finding(:fanout_dispatches_once_per_matching_row, history)).to be(true)
    end

    it "aggregation_matches_recompute names a count that disagrees with the recomputed eligible rows" do
      instances = [card_payment(1, "acct-1", "disputed"), card_payment(2, "acct-1", "disputed"),
                   card_payment(3, "acct-1", "authorized")].to_h
      history = payment_history("Banking.disputed_payment_count", instances, [{ account: {}, card_payments: 99 }])

      expect(finding(:aggregation_matches_recompute, history)).to be_a(String).and include("99", "2")
    end

    it "aggregation_matches_recompute passes a count that matches the recomputed eligible rows" do
      instances = [card_payment(1, "acct-1", "disputed"), card_payment(2, "acct-1", "disputed"),
                   card_payment(3, "acct-1", "authorized"), card_payment(4, "acct-2", "disputed")].to_h
      history = payment_history("Banking.disputed_payment_count", instances, [{ account: {}, card_payments: 2 }])

      expect(finding(:aggregation_matches_recompute, history)).to be(true)
    end

    it "aggregation_matches_recompute passes a median matching the interpreter's own even/odd convention" do
      instances = [card_payment(1, "acct-1", "disputed", amount: { cents: 100 }),
                   card_payment(2, "acct-1", "disputed", amount: { cents: 300 })].to_h
      history = payment_history("Banking.disputed_payment_median", instances, [{ account: {}, card_payments: 200.0 }])

      expect(finding(:aggregation_matches_recompute, history)).to be(true)
    end

    it "stored_records_satisfy_declared_invariants names a stored balance that violates Account's own invariant" do
      result = finding(:stored_records_satisfy_declared_invariants, account_history(-500))

      expect(result).to be_a(String).and include("Banking::Account#a1", "the balance never goes negative")
    end

    it "stored_records_satisfy_declared_invariants passes a stored balance that holds the invariant" do
      expect(finding(:stored_records_satisfy_declared_invariants, account_history(500))).to be(true)
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
      history = accounts_by_kind_history(account_instances("current", "savings", "current"), [{ accounts: {} }])

      expect(finding(:group_by_matches_recompute, history)).to be_a(String)
        .and include("Banking.accounts_by_kind", "3 eligible row(s)")
    end

    it "group_by_matches_recompute passes a grouping that matches the recomputed nesting" do
      grouped = { "current" => { "a1" => { daily_limit: { cents: 0 }, id: "a1" } },
                  "savings" => { "a2" => { daily_limit: { cents: 0 }, id: "a2" } } }
      history = accounts_by_kind_history(account_instances("current", "savings"), [{ accounts: grouped }])

      expect(finding(:group_by_matches_recompute, history)).to be(true)
    end

    # ADR 0061, decision D1: a group_by leaf holds one row. `PartsByBin`
    # groups by `bin` alone, so two parts in one bin must refuse; the oracle
    # finds the shared key path from the rows, never from a nesting.
    it "group_by_matches_recompute names an answer given where two eligible rows share a key path" do
      history = parts_history("GroupByCollisionFixture.PartsByBin", rows: [{ parts: { "b1" => { ref: "p1", id: "p1" } } }])

      expect(finding(:group_by_matches_recompute, history)).to be_a(String)
        .and include("GroupByCollisionFixture.PartsByBin", "so the ask must refuse")
    end

    it "group_by_matches_recompute passes a refusal where two eligible rows share a key path" do
      history = parts_history("GroupByCollisionFixture.PartsByBin", rows: nil, error: "PartsByBin groups by bin, but rows ...")

      expect(finding(:group_by_matches_recompute, history)).to be(true)
    end

    it "group_by_matches_recompute expects an answer when the key path covers the identity" do
      rows = [{ parts: { "b1" => { "p1" => { id: "p1" }, "p2" => { id: "p2" } }, "b2" => { "p3" => { id: "p3" } } } }]
      history = parts_history("GroupByCollisionFixture.PartsByBinAndRef", rows: rows)

      expect(finding(:group_by_matches_recompute, history)).to be(true)
    end
  end
end
