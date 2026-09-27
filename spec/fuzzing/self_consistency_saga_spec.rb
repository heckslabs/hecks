require "spec_helper"
require "hecks/fuzzing"
require "hecks/fuzzing/self_consistency"

# Saga cold-rehydration and redelivery idempotency, against the waybill stress domain's
# `Packing` process manager.
RSpec.describe "Hecks::Fuzzing::SelfConsistency saga cold-rehydration (ANGLE-10)" do
  # File-unique constant names: a bare name inside `describe` lands on Object, and
  # load_hygiene_spec refuses collisions across spec files.
  SAGA_REHYDRATION_WAYBILL_ROOT = File.join(InMemoryDomain::ROOT, "qa/stress_domains/waybill").freeze
  SAGA_REHYDRATION_PIZZAS_ROOT  = File.join(InMemoryDomain::ROOT, "examples/pizzas").freeze

  SAGA_REHYDRATION_STEPS = [
    { "verb" => "Waybill::Consignment.Request",
      "args" => { "reference" => { "value" => "R1" }, "number" => { "value" => 1 },
                 "item" => { "text" => "widget" } } }
  ].freeze

  # A reaction depth of 3 stops leg 4 (Ship) from running, leaving `Packing` checkpointed at
  # "filled"; the synchronous cascade cannot be paused any other way.
  def replay_waybill
    stub_const("Hecks::Runtime::Dispatcher::MAX_REACTION_DEPTH", 3)
    Hecks::Fuzzing::Replay.call(SAGA_REHYDRATION_WAYBILL_ROOT, SAGA_REHYDRATION_STEPS, self_consistency: true)
  end

  # Swaps `each_saga` for a transformed read and restores it in `ensure`. It returns an
  # Enumerator without a block, like SagaStore#each_saga, because callers chain onto it.
  # `transform` is an explicit lambda since the caller already passes the block.
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

    # Precondition: the saga is still live and stuck, so the checks below cannot pass vacuously.
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
      # Seeded bug: rehydration answers "filling" instead of "filled", so redelivering SlotFilled
      # matches leg 4 again and dispatches Consignment::Ship a second time.
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

    # The redelivery probe's `advance_saga` appends to `saga_log`, which `Replay.call` returns by
    # reference; an unrestored append leaks into the primary `sagas` trace and reads as a false
    # "diverged on: sagas" in diff_ruby_vs_rust. The trace must match with the mode on or off.
    it "does not leak the redelivery probe's own saga_log row into the primary sagas trace" do
      stub_const("Hecks::Runtime::Dispatcher::MAX_REACTION_DEPTH", 3)
      without_self_consistency =
        Hecks::Fuzzing::Replay.call(SAGA_REHYDRATION_WAYBILL_ROOT, SAGA_REHYDRATION_STEPS, self_consistency: false)
      with_self_consistency =
        Hecks::Fuzzing::Replay.call(SAGA_REHYDRATION_WAYBILL_ROOT, SAGA_REHYDRATION_STEPS, self_consistency: true)

      # The probe genuinely ran: the stuck "filled" instance has no handler for SlotFilled, so
      # advance_saga appends a leg-mismatch row every time, making this more than a vacuous pass.
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
