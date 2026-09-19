require "spec_helper"
require "hecks/fuzzing"
require "hecks/fuzzing/self_consistency"

# Angle-10 — saga cold-rehydration, the one axis `spec/fuzzing/self_
# consistency_spec.rb` never touches: that file's own three checks all
# cold-read an aggregate's own journal through Heki; nothing anywhere
# ever proved `Registry#rehydrate_sagas!` — the real "process just
# restarted" path for a `process_manager` — faithful for a sequence this
# practice actually generated, or that redelivering an already-seen
# event to a rehydrated instance is a no-op. `qa/stress_domains/waybill`
# is the corpus's own saga stress domain (BUG#6/#9/#10 all came out of
# its `Packing` process manager), so this spec stays there rather than
# reaching for a fixture.
#
# **The one crafted step, and why it stops where it does** — `Packing`'s own
# four legs (Open -> AddSlot -> Fill -> Ship, `waybill.bluebook`'s own
# header) all cascade synchronously inside one `Consignment.Request`
# dispatch (`SagaInterpreter#deliver_saga_dispatch`'s own `@door.reenter`
# call re-enters the same dispatch chain), so there is no external way to
# pause the cascade mid-flight without either a genuine domain refusal or
# hitting the reaction-depth ceiling — and every genuine refusal this
# domain's own data can produce (Fill failing, say) already has a
# declared `:refused, from: "filling"` compensating leg, so it never gets
# stuck; it lands on "cancelled" instead, dispatched through the synthetic
# `REFUSED` trigger, which names no real domain event at all — nothing an
# idempotency check could redeliver.
#
# `Dispatcher::MAX_REACTION_DEPTH` stubbed to 3 (`stub_const`, `spec/
# runtime/dispatcher_spec.rb`'s own well-established boundary) is what
# gets a real, naturally-arising stuck instance instead: legs 1-3 each
# `reenter` once (Open at depth 1, AddSlot at depth 2, Fill at depth 3),
# all under the ceiling; leg 4's own `reenter` (Ship) checks depth 3 >= 3
# and refuses to run at all. `advance_saga`'s own checkpoint-before-
# dispatch design (`saga_interpreter.rb`'s own comment) has already moved
# the instance to "filled" by the time that ceiling check fires, and
# `unwind` finds no `:refused` handler declared `from: "filled"` (only
# `"filling"` has one) — so the instance is left checkpointed, live, in
# `saga_instances`, and never reaches `ends_on` (`ConsignmentShipped`
# never actually fires). A real, forward (`from != to`) transition — not
# a self-loop — with a real domain event (`SlotFilled`) behind it.
RSpec.describe "Hecks::Fuzzing::SelfConsistency saga cold-rehydration (ANGLE-10)" do
  # **Distinctive, file-unique names** — `spec/load_hygiene_spec.rb`'s own
  # "lets no two spec files disagree about a top-level constant" refuses
  # any bare `NAME = ...` inside an `RSpec.describe` block that collides
  # with another spec file's own (a `describe` block is not a real
  # namespace, so a plain assignment lands on `Object` either way) —
  # `PIZZAS`/`WAYBILL`/`STEPS` are all already taken elsewhere
  # (`spec/fuzzing/adversary_spec.rb`, `spec/waybill_spec.rb`, `spec/
  # fuzzing/self_consistency_spec.rb`), found live: a shared, last-file-
  # loaded-wins `STEPS` silently fed this file's own examples the wrong
  # domain's step list under `bundle exec rspec spec/fuzzing`.
  SAGA_REHYDRATION_WAYBILL_ROOT = File.join(InMemoryDomain::ROOT, "qa/stress_domains/waybill").freeze
  SAGA_REHYDRATION_PIZZAS_ROOT  = File.join(InMemoryDomain::ROOT, "examples/pizzas").freeze

  SAGA_REHYDRATION_STEPS = [
    { "verb" => "Waybill::Consignment.Request",
      "args" => { "reference" => { "value" => "R1" }, "number" => { "value" => 1 },
                 "item" => { "text" => "widget" } } }
  ].freeze

  def replay_waybill
    stub_const("Hecks::Runtime::Dispatcher::MAX_REACTION_DEPTH", 3)
    Hecks::Fuzzing::Replay.call(SAGA_REHYDRATION_WAYBILL_ROOT, SAGA_REHYDRATION_STEPS, self_consistency: true)
  end

  # Wrap-and-restore, the same idiom `self_consistency_spec.rb` already
  # established for breaking one real production code path and proving a
  # follow-up run is clean again — an `UnboundMethod` captured before the
  # break, reinstalled in `ensure`. `return enum_for(:each_saga, domain)
  # unless blk` mirrors `SagaStore#each_saga`'s own no-block contract
  # exactly (`cold_read_saga_rows`/`check_one_saga_redelivery` both call
  # `each_saga` bare, chaining `.each_with_object`/`.find` onto the
  # returned Enumerator) — without it, the corrupted override would only
  # ever fire for a caller that hands `each_saga` a block directly.
  # `transform` — a `->(blk, pm, corr, state, memory, comp) { blk.call(pm, corr, ...) }`
  # lambda, taken as an explicit argument rather than the method's own
  # block, because the caller already needs its own block (the replay
  # to run under the corruption) — Ruby has only one implicit block per
  # call.
  def corrupt_each_saga(transform)
    original = Hecks::Adapters::Heki::SagaStore.instance_method(:each_saga)
    Hecks::Adapters::Heki::SagaStore.send(:define_method, :each_saga) do |domain, &blk|
      return enum_for(:each_saga, domain) unless blk

      original.bind(self).call(domain) { |pm, corr, state, memory, comp| transform.call(blk, pm, corr, state, memory, comp) }
    end
    yield
  ensure
    Hecks::Adapters::Heki::SagaStore.send(:define_method, :each_saga, original)
  end

  it "is clean against a real generated cascade, with the saga genuinely still live and stuck" do
    history  = replay_waybill
    findings = history.fetch(:self_consistency)

    # **The precondition** — if this domain's own bluebook or the reaction-
    # depth mechanics it leans on ever change, this fails loudly here
    # rather than the two assertions below silently passing for the
    # wrong reason ("nothing to check" instead of "checked, and clean").
    expect(history[:saga_instances]["Packing"]).to match("R1" => hash_including(state: "filled"))

    expect(findings[:saga_rehydration]).to eq([])
    expect(findings[:saga_redelivery_idempotency]).to eq([])
  end

  describe "check 4 — saga rehydration" do
    it "fires when cold-reading a durable saga checkpoint silently drops memory" do
      drop_memory = ->(blk, pm, corr, state, _memory, comp) { blk.call(pm, corr, state, {}, comp) }
      findings = corrupt_each_saga(drop_memory) { replay_waybill.fetch(:self_consistency) }

      expect(findings[:saga_rehydration]).not_to be_empty
      finding = findings[:saga_rehydration].first
      expect(finding[:field]).to eq("saga_rehydration")
      expect(finding[:domain]).to eq("Waybill")
      expect(finding[:process_manager]).to eq("Packing")
      expect(finding[:rehydrated]["R1"][:memory]).to eq({})
      expect(finding[:live]["R1"][:memory]).not_to eq({})
    end

    it "is clean again once the read path is restored" do
      expect(replay_waybill.fetch(:self_consistency)[:saga_rehydration]).to eq([])
    end
  end

  describe "check 5 — saga redelivery idempotency" do
    it "fires when a corrupted rehydration reverts the checkpoint to an earlier, still-matching state" do
      # **The seeded bug** — a rehydration that answers "filling" (the state
      # before leg 4 ever ran) instead of the real last-checkpointed
      # "filled". `handler_for("SlotFilled", "filling")` genuinely
      # matches leg 4 again, so redelivering the saga's own last real
      # event through the real interpreter re-advances it for real —
      # dispatching `Consignment::Ship` a second time, which this time
      # succeeds (nothing blocked it), and the instance reaches `ends_on`
      # and is deleted — about as visible a "advanced again" as a
      # rehydration bug could produce.
      revert_state = ->(blk, pm, corr, _state, memory, comp) { blk.call(pm, corr, "filling", memory, comp) }
      findings = corrupt_each_saga(revert_state) { replay_waybill.fetch(:self_consistency) }

      expect(findings[:saga_redelivery_idempotency]).not_to be_empty
      finding = findings[:saga_redelivery_idempotency].first
      expect(finding[:field]).to eq("saga_redelivery_idempotency")
      expect(finding[:domain]).to eq("Waybill")
      expect(finding[:process_manager]).to eq("Packing")
      expect(finding[:correlation]).to eq("R1")
      expect(finding[:on]).to eq("SlotFilled")
      expect(finding[:before][:state]).to eq("filling")
      expect(finding[:after]).to be_nil
    end

    it "is clean again once the read path is restored" do
      expect(replay_waybill.fetch(:self_consistency)[:saga_redelivery_idempotency]).to eq([])
    end

    # BUG#39 — `check_one_saga_redelivery`'s own probe dispatch
    # (`interpreter.advance`, above) drives a real `SagaInterpreter#
    # advance_saga`, which appends its own row to `@registry.saga_log`
    # unconditionally — success, "no conversation", or (this fixture's
    # own case) a leg mismatch alike, regardless of whether the
    # redelivery check itself finds anything worth reporting. That array
    # is `history[:sagas]` — `Replay.call` hands it out by reference, not
    # a copy — so an unrestored probe append shows up as a third-party
    # row in the primary event-dispatch trace, indistinguishable from a
    # real dispatch that never happened. `diff_ruby_vs_rust` (`bin/
    # qa_sweep`) diffs exactly this field against Rust's own single-pass,
    # probe-free `sagas` output, so the leak surfaced there as a spurious
    # "diverged on: sagas" finding — a false positive, not a real
    # Ruby/Rust divergence. Pinned here the same way `replay_spec.rb`'s
    # own "is deterministic" example pins a different invariant: the
    # primary trace must come out byte-identical whether or not
    # self-consistency mode ran alongside it.
    it "does not leak the redelivery probe's own saga_log row into the primary sagas trace" do
      stub_const("Hecks::Runtime::Dispatcher::MAX_REACTION_DEPTH", 3)
      without_self_consistency =
        Hecks::Fuzzing::Replay.call(SAGA_REHYDRATION_WAYBILL_ROOT, SAGA_REHYDRATION_STEPS, self_consistency: false)
      with_self_consistency =
        Hecks::Fuzzing::Replay.call(SAGA_REHYDRATION_WAYBILL_ROOT, SAGA_REHYDRATION_STEPS, self_consistency: true)

      # **The probe genuinely ran** — proof this isn't a vacuous "nothing to
      # redeliver" pass: the stuck "filled" instance has no handler for a
      # redelivered SlotFilled, so `advance_saga` takes its leg-mismatch
      # branch and appends a row, every time, whether or not this
      # assertion's own `eq` below would have caught its leak.
      expect(with_self_consistency[:sagas].size).to eq(without_self_consistency[:sagas].size)
      expect(with_self_consistency[:sagas]).to eq(without_self_consistency[:sagas])
    end
  end

  describe "a domain with no process manager at all" do
    it "skips cleanly — no findings, not a claimed pass" do
      steps    = Hecks::Fuzzing::SequenceGenerator.generate(SAGA_REHYDRATION_PIZZAS_ROOT, seed: 2, steps: 10)
      findings = Hecks::Fuzzing::Replay.call(SAGA_REHYDRATION_PIZZAS_ROOT, steps, self_consistency: true)
                                       .fetch(:self_consistency)

      expect(findings[:saga_rehydration]).to eq([])
      expect(findings[:saga_redelivery_idempotency]).to eq([])
    end
  end
end
