# spec/hecks/runtime/llm_dispatcher_spec.rb
#
# Contract for Hecks::Runtime::LlmDispatcher. Exercises placeholder
# substitution from prompt_template, provider resolution (explicit map
# + default :test), Result wrapping, and the Skipped/Failed surfaces.
#
$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "hecks"

RSpec.describe Hecks::Runtime::LlmDispatcher do
  def adapter(overrides = {})
    attrs = {
      name: :greet,
      prompt_template: "Hello {{name}}",
      model: "test-model",
      max_tokens: 50,
      backend: :test,
    }.merge(overrides)
    Hecksagon::Structure::LlmAdapter.new(**attrs)
  end

  let(:test_provider_class) { Hecks::Runtime::LlmProviders::TestProvider }

  def fixture_provider(prompt_to_response)
    fixtures = prompt_to_response.transform_keys { |k| test_provider_class.hash_for(k) }
    test_provider_class.new(fixtures: fixtures)
  end

  describe ".substitute_placeholders" do
    it "substitutes {{name}} tokens from the template" do
      out = described_class.substitute_placeholders("Hi {{who}}!", who: "Miette")
      expect(out).to eq("Hi Miette!")
    end

    it "accepts string or symbol keys" do
      out = described_class.substitute_placeholders("{{a}}-{{b}}", "a" => "x", b: "y")
      expect(out).to eq("x-y")
    end

    it "leaves unknown placeholders untouched" do
      out = described_class.substitute_placeholders("{{missing}} hi", {})
      expect(out).to eq("{{missing}} hi")
    end

    it "stringifies non-string substitution values" do
      out = described_class.substitute_placeholders("count={{n}}", n: 42)
      expect(out).to eq("count=42")
    end

    it "substitutes the same placeholder in multiple positions" do
      out = described_class.substitute_placeholders("{{x}} and {{x}}", x: "yo")
      expect(out).to eq("yo and yo")
    end
  end

  describe ".call" do
    it "substitutes the prompt and returns the fixture response wrapped in Result" do
      provider = fixture_provider("Hello Miette" => "Bonjour, Miette.")
      result = described_class.call(adapter, { name: "Miette" }, providers: { test: provider })

      expect(result).to be_a(Hecks::Runtime::LlmDispatcher::Result)
      expect(result.response_text).to eq("Bonjour, Miette.")
      expect(result.prompt).to eq("Hello Miette")
      expect(result.provider).to eq(:test)
      expect(result.model_used).to eq("test-model")
      expect(result.tokens_in).to eq(2)
      expect(result.tokens_out).to be > 0
      expect(result.raw[:digest]).to eq(test_provider_class.hash_for("Hello Miette"))
    end

    it "defaults backend to :test when adapter.backend is nil and constructs a default provider" do
      a = Hecksagon::Structure::LlmAdapter.new(
        name: :no_backend,
        prompt_template: "ping",
        backend: nil,
      )
      result = described_class.call(a)
      # Lenient default TestProvider returns a synthetic placeholder.
      expect(result.provider).to eq(:test)
      expect(result.response_text).to include("[test-provider:unknown-prompt")
    end

    it "returns Skipped(provider_unavailable) when backend is unknown and providers map is empty" do
      a = adapter(backend: :claude)
      out = described_class.call(a, {}, providers: {})
      expect(out).to be_a(described_class::Skipped)
      expect(out.reason).to eq("provider_unavailable")
      expect(out.details[:provider]).to eq(:claude)
    end

    it "raises LlmInvocationFailed when the strict TestProvider has no fixture" do
      strict = test_provider_class.new(strict: true)
      expect {
        described_class.call(adapter, { name: "X" }, providers: { test: strict })
      }.to raise_error(Hecks::LlmInvocationFailed) do |err|
        expect(err.reason).to eq("fixture_missing")
        expect(err.provider).to eq(:test)
      end
    end

    it "wraps a generic LlmAdapterError from the provider as LlmInvocationFailed(transport_error)" do
      flaky = Class.new do
        def name; :flaky; end
        def invoke(**)
          raise Hecks::LlmAdapterError.new("boom", adapter: :greet, provider: :flaky)
        end
      end.new

      expect {
        described_class.call(adapter, {}, providers: { test: flaky })
      }.to raise_error(Hecks::LlmInvocationFailed) do |err|
        expect(err.reason).to eq("transport_error")
        expect(err.provider).to eq(:test)
        expect(err.adapter).to eq(:greet)
        expect(err.message).to include("boom")
      end
    end

    it "propagates an already-structured LlmInvocationFailed from the provider untouched" do
      raiser = Class.new do
        def name; :raiser; end
        def invoke(**)
          raise Hecks::LlmInvocationFailed.new(
            "no fixture", provider: :test, reason: "fixture_missing"
          )
        end
      end.new

      expect {
        described_class.call(adapter, {}, providers: { test: raiser })
      }.to raise_error(Hecks::LlmInvocationFailed) do |err|
        expect(err.reason).to eq("fixture_missing")
        expect(err.message).to eq("no fixture")
      end
    end

    it "passes adapter.model + max_tokens through to the provider" do
      seen = {}
      capturing = Class.new do
        define_method(:invoke) do |prompt:, model:, max_tokens:, stream: false|
          seen[:prompt] = prompt
          seen[:model] = model
          seen[:max_tokens] = max_tokens
          seen[:stream] = stream
          Hecks::Runtime::LlmProviders::Result.new(
            response_text: "ok", tokens_in: 1, tokens_out: 1, model_used: model, raw: nil
          )
        end
      end.new

      a = adapter(model: "claude-x", max_tokens: 99)
      described_class.call(a, { name: "Z" }, providers: { test: capturing }, stream: true)

      expect(seen).to eq(
        prompt: "Hello Z",
        model: "claude-x",
        max_tokens: 99,
        stream: true
      )
    end

    it "uses provider.invoke result.model_used in preference to adapter.model when present" do
      provider = Class.new do
        def invoke(**)
          Hecks::Runtime::LlmProviders::Result.new(
            response_text: "ok", tokens_in: 0, tokens_out: 0,
            model_used: "actual-model-id", raw: nil
          )
        end
      end.new
      result = described_class.call(adapter, {}, providers: { test: provider })
      expect(result.model_used).to eq("actual-model-id")
    end
  end
end
