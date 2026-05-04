# spec/hecks/runtime/llm_providers/test_provider_spec.rb
#
# Contract for Hecks::Runtime::LlmProviders::TestProvider — fixture
# table, lenient vs strict miss handling, env-driven strict mode,
# token estimation, capture-path seam.
#
$LOAD_PATH.unshift File.expand_path("../../../../lib", __dir__)
require "hecks"

RSpec.describe Hecks::Runtime::LlmProviders::TestProvider do
  let(:hash_for_hi) { described_class.hash_for("hi") }

  describe ".hash_for" do
    it "returns a stable SHA-256 hex digest of the prompt" do
      expect(described_class.hash_for("hi"))
        .to eq("8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4")
    end

    it "stringifies non-string input" do
      expect(described_class.hash_for(42)).to eq(described_class.hash_for("42"))
    end
  end

  describe "#name" do
    it "is :test" do
      expect(described_class.new.name).to eq(:test)
    end
  end

  describe "#invoke" do
    it "returns the canned response when the prompt hash is in fixtures" do
      provider = described_class.new(fixtures: { hash_for_hi => "hello back" })
      result = provider.invoke(prompt: "hi", model: "claude-test", max_tokens: 64)
      expect(result).to be_a(Hecks::Runtime::LlmProviders::Result)
      expect(result.response_text).to eq("hello back")
      expect(result.model_used).to eq("claude-test")
      expect(result.raw[:provider]).to eq(:test)
      expect(result.raw[:digest]).to eq(hash_for_hi)
      expect(result.raw[:max_tokens]).to eq(64)
    end

    it "estimates tokens by whitespace-splitting prompt and response" do
      provider = described_class.new(
        fixtures: { described_class.hash_for("one two three") => "a b" }
      )
      result = provider.invoke(prompt: "one two three", model: nil, max_tokens: nil)
      expect(result.tokens_in).to eq(3)
      expect(result.tokens_out).to eq(2)
    end

    it "in lenient mode returns a synthetic placeholder for an unknown prompt" do
      provider = described_class.new
      result = provider.invoke(prompt: "novel", model: nil, max_tokens: nil)
      expect(result.response_text).to include("[test-provider:unknown-prompt")
      expect(result.response_text).to include(described_class.hash_for("novel"))
    end

    it "in strict mode (constructor flag) raises LlmInvocationFailed(fixture_missing)" do
      provider = described_class.new(strict: true)
      expect {
        provider.invoke(prompt: "novel", model: nil, max_tokens: nil)
      }.to raise_error(Hecks::LlmInvocationFailed) do |err|
        expect(err.reason).to eq("fixture_missing")
        expect(err.provider).to eq(:test)
        expect(err.message).to include(described_class.hash_for("novel"))
      end
    end

    it "honors HECKS_LLM_FIXTURE_STRICT=1 from injected env" do
      provider = described_class.new(env: { "HECKS_LLM_FIXTURE_STRICT" => "1" })
      expect(provider.strict?).to be true
      expect {
        provider.invoke(prompt: "x", model: nil, max_tokens: nil)
      }.to raise_error(Hecks::LlmInvocationFailed)
    end

    it "treats any HECKS_LLM_FIXTURE_STRICT value other than '1' as lenient" do
      provider = described_class.new(env: { "HECKS_LLM_FIXTURE_STRICT" => "true" })
      expect(provider.strict?).to be false
    end

    it "accepts symbol-keyed fixtures and stringifies them at construction" do
      provider = described_class.new(fixtures: { hash_for_hi.to_sym => "ok" })
      result = provider.invoke(prompt: "hi", model: nil, max_tokens: nil)
      expect(result.response_text).to eq("ok")
    end

    it "exposes capture_path from HECKS_LLM_CAPTURE env (seam, not yet active)" do
      provider = described_class.new(env: { "HECKS_LLM_CAPTURE" => "/tmp/cap.yml" })
      expect(provider.capture_path).to eq("/tmp/cap.yml")
    end

    it "ignores the stream flag (TestProvider is non-streaming) but echoes it on raw" do
      provider = described_class.new(fixtures: { hash_for_hi => "yo" })
      result = provider.invoke(prompt: "hi", model: nil, max_tokens: nil, stream: true)
      expect(result.response_text).to eq("yo")
      expect(result.raw[:stream]).to eq(true)
    end
  end

  describe "#fixture_count" do
    it "reports the number of registered fixtures" do
      provider = described_class.new(
        fixtures: { hash_for_hi => "a", described_class.hash_for("yo") => "b" }
      )
      expect(provider.fixture_count).to eq(2)
    end
  end
end
