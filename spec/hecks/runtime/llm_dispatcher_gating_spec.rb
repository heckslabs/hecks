# spec/hecks/runtime/llm_dispatcher_gating_spec.rb
#
# Step 6 concerns : the i23 §4 gating pipeline around the bare dispatcher.
# Exercises CircuitBreaker.open?, Spend.over_budget? + override bypass,
# success-path record_call + record_success, failure-path record_failure,
# crash ordering (record_call failure does NOT lose the response),
# and the Skipped emission for breaker_open / budget_exceeded /
# provider_unavailable.
#
# Companion spec : llm_dispatcher_spec.rb (step 4 — placeholder
# substitution + provider resolution + bare invoke).
#
$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "hecks"
require_relative "llm_dispatcher_doubles"

RSpec.describe Hecks::Runtime::LlmDispatcher do
  def adapter(overrides = {})
    attrs = {
      name: :greet,
      prompt_template: "Hello {{name}}",
      model: "test-model",
      max_tokens: 50,
      response_into_target: "Greeter.Greeted",
      backend: :test,
    }.merge(overrides)
    Hecksagon::Structure::LlmAdapter.new(**attrs)
  end

  let(:provider) { LlmDispatcherDoubles::FakeProvider.new(response_text: "ok") }
  let(:logger)   { LlmDispatcherDoubles::FakeLogger.new }
  let(:clock)    { Time.utc(2026, 5, 2, 12, 0, 0) }

  describe "breaker preflight" do
    it "returns Skipped(breaker_open) when the breaker is open" do
      breaker = LlmDispatcherDoubles::FakeBreaker.new(open: true)
      result = described_class.call(adapter, {}, providers: { test: provider },
                                    breaker: breaker, logger: logger, now: clock)
      expect(result).to be_skipped
      expect(result.reason).to eq("breaker_open")
      expect(provider.calls).to be_empty
      expect(logger.event_names).to include("LlmInvocationSkipped")
    end

    it "uses 'greet_api' (#{'#{adapter.name}_api'}) as the default breaker_kind" do
      breaker = LlmDispatcherDoubles::FakeBreaker.new(open: true)
      described_class.call(adapter, {}, providers: { test: provider },
                           breaker: breaker, logger: logger)
      skipped_event = logger.events.find { |e| e[:event] == "LlmInvocationSkipped" }
      expect(skipped_event[:kind]).to eq("greet_api")
    end

    it "honors a breaker_kind override" do
      breaker = LlmDispatcherDoubles::FakeBreaker.new(open: true)
      described_class.call(adapter, {}, providers: { test: provider },
                           breaker: breaker, breaker_kind: "custom", logger: logger)
      skipped_event = logger.events.find { |e| e[:event] == "LlmInvocationSkipped" }
      expect(skipped_event[:kind]).to eq("custom")
    end
  end

  describe "spend preflight" do
    it "returns Skipped(budget_exceeded) when spend.over_budget? is true" do
      spend = LlmDispatcherDoubles::FakeSpend.new(over_budget: true)
      result = described_class.call(adapter, {}, providers: { test: provider },
                                    spend: spend, logger: logger, now: clock)
      expect(result).to be_skipped
      expect(result.reason).to eq("budget_exceeded")
      expect(provider.calls).to be_empty
    end

    it "bypasses the budget when override_active? returns true" do
      spend = LlmDispatcherDoubles::FakeSpend.new(over_budget: true, override: true)
      result = described_class.call(adapter, {}, providers: { test: provider },
                                    spend: spend, logger: logger, now: clock)
      expect(result).to be_completed
      expect(logger.event_names).to include("LlmInvocationOverbudgetBypass")
    end
  end

  describe "success path" do
    it "records the call on Spend with token telemetry" do
      spend = LlmDispatcherDoubles::FakeSpend.new
      described_class.call(adapter, {}, providers: { test: provider },
                           spend: spend, now: clock)
      expect(spend.recorded_calls.size).to eq(1)
      expect(spend.recorded_calls.first[:provider]).to eq("test")
      expect(spend.recorded_calls.first[:command_ref]).to eq("Greeter.Greeted")
    end

    it "records a success on the breaker" do
      breaker = LlmDispatcherDoubles::FakeBreaker.new
      described_class.call(adapter, {}, providers: { test: provider },
                           breaker: breaker, now: clock)
      expect(breaker.successes).to eq(["greet_api"])
    end

    it "logs LlmInvocationCompleted" do
      described_class.call(adapter, {}, providers: { test: provider },
                           logger: logger, now: clock)
      expect(logger.event_names).to include("LlmInvocationCompleted")
    end

    it "still returns the Result when record_call raises (crash ordering)" do
      flaky_spend = LlmDispatcherDoubles::FakeSpend.new(raise_on_record: StandardError.new("disk"))
      result = described_class.call(adapter, {}, providers: { test: provider },
                                    spend: flaky_spend, logger: logger, now: clock)
      expect(result).to be_completed
      expect(result.response_text).to eq("ok")
      expect(logger.event_names).to include("spend_record_call_failed", "LlmInvocationCompleted")
    end
  end

  describe "failure path" do
    let(:failing_provider) do
      LlmDispatcherDoubles::FakeProvider.new(raises: Hecks::LlmAdapterError.new("network down"))
    end

    it "records a failure on the breaker and re-raises as LlmInvocationFailed" do
      breaker = LlmDispatcherDoubles::FakeBreaker.new
      expect {
        described_class.call(adapter, {}, providers: { test: failing_provider },
                             breaker: breaker, logger: logger, now: clock)
      }.to raise_error(Hecks::LlmInvocationFailed)
      expect(breaker.failures).to eq(["greet_api"])
      expect(logger.event_names).to include("LlmInvocationFailed")
    end
  end

  describe "ports-disabled paths" do
    it "runs cleanly with neither spend nor breaker wired" do
      result = described_class.call(adapter, { name: "World" },
                                    providers: { test: provider }, logger: logger)
      expect(result).to be_completed
      expect(logger.event_names).to include("LlmInvocationCompleted")
    end

    it "returns Skipped(provider_unavailable) when the backend has no provider" do
      result = described_class.call(adapter(backend: :nonexistent), {},
                                    providers: { test: provider }, logger: logger)
      expect(result).to be_skipped
      expect(result.details[:provider]).to eq(:nonexistent)
    end
  end
end
