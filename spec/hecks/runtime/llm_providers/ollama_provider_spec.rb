# spec/hecks/runtime/llm_providers/ollama_provider_spec.rb
#
# Contract for Hecks::Runtime::LlmProviders::OllamaProvider. Exercises:
#   - default URL (http://localhost:11434) + override via ctor
#   - boot probe success / failure → degraded? state
#   - unary invocation : POST /api/generate, parsed Result
#   - streaming invocation : NDJSON parsing, chunk yielding,
#     final token counts captured from done-true terminator
#   - LlmInvocationSkipped when degraded
#   - LlmAdapterError on non-200 / connection refused
#
# All HTTP is stubbed — Net::HTTP doubled out, zero real network.
$LOAD_PATH.unshift File.expand_path("../../../../../ruby", __dir__)
require "hecks"
require "hecks/runtime"

RSpec.describe Hecks::Runtime::LlmProviders::OllamaProvider do
  let(:provider) { described_class.new(url: "http://localhost:11434") }
  let(:fake_http) { instance_double(Net::HTTP) }

  before do
    allow(Net::HTTP).to receive(:new).and_return(fake_http)
    allow(fake_http).to receive(:use_ssl=)
  end

  describe "#new" do
    it "defaults to localhost:11434" do
      expect(described_class.new.url).to eq("http://localhost:11434")
    end

    it "respects an override url" do
      expect(described_class.new(url: "http://gpu:9999").url).to eq("http://gpu:9999")
    end
  end

  describe "#boot_probe" do
    it "marks healthy on 200 from /api/tags" do
      ok = double("response", code: "200")
      expect(fake_http).to receive(:request).with(an_instance_of(Net::HTTP::Get)).and_return(ok)
      expect(provider.boot_probe).to be true
      expect(provider.degraded?).to be false
    end

    it "marks degraded on non-2xx" do
      bad = double("response", code: "500")
      expect(fake_http).to receive(:request).and_return(bad)
      expect(provider.boot_probe).to be false
      expect(provider.degraded?).to be true
      expect(provider.degraded_reason).to include("500")
    end

    it "marks degraded on connection refused" do
      expect(fake_http).to receive(:request).and_raise(Errno::ECONNREFUSED)
      expect(provider.boot_probe).to be false
      expect(provider.degraded?).to be true
    end
  end

  describe "#invoke when degraded" do
    it "raises LlmInvocationSkipped(reason: 'provider_unavailable')" do
      allow(fake_http).to receive(:request).and_raise(Errno::ECONNREFUSED)
      provider.boot_probe
      expect {
        provider.invoke(prompt: "p", model: "llama3", max_tokens: 50)
      }.to raise_error(Hecks::LlmInvocationSkipped) { |e|
        expect(e.reason).to eq("provider_unavailable")
      }
    end
  end

  describe "#invoke (unary)" do
    let(:body) do
      {
        "model" => "llama3",
        "response" => "hi from ollama",
        "prompt_eval_count" => 9,
        "eval_count" => 4,
        "done" => true
      }.to_json
    end
    let(:res200) { double("response", code: "200", body: body) }

    it "POSTs to /api/generate with the right JSON body" do
      seen_req = nil
      allow(fake_http).to receive(:request) do |req|
        seen_req = req
        res200
      end
      provider.invoke(prompt: "hi", model: "llama3", max_tokens: 200)
      expect(seen_req.path).to eq("/api/generate")
      payload = JSON.parse(seen_req.body)
      expect(payload["model"]).to eq("llama3")
      expect(payload["prompt"]).to eq("hi")
      expect(payload["stream"]).to be false
      expect(payload.dig("options", "num_predict")).to eq(200)
    end

    it "returns a Result populated from the response body" do
      allow(fake_http).to receive(:request).and_return(res200)
      result = provider.invoke(prompt: "hi", model: "llama3", max_tokens: 200)
      expect(result.response_text).to eq("hi from ollama")
      expect(result.tokens_in).to eq(9)
      expect(result.tokens_out).to eq(4)
      expect(result.model_used).to eq("llama3")
    end

    it "raises LlmAdapterError on non-200" do
      bad = double("response", code: "503", body: "down")
      allow(fake_http).to receive(:request).and_return(bad)
      expect {
        provider.invoke(prompt: "p", model: "m", max_tokens: 1)
      }.to raise_error(Hecks::LlmAdapterError, /503/)
    end

    it "wraps unexpected transport errors as LlmAdapterError" do
      allow(fake_http).to receive(:request).and_raise(Errno::ECONNRESET.new("reset"))
      expect {
        provider.invoke(prompt: "p", model: "m", max_tokens: 1)
      }.to raise_error(Hecks::LlmAdapterError, /transport error/)
    end
  end

  describe "#invoke (stream)" do
    # Helper: simulate Net::HTTP#request with a streaming response —
    # invokes the block with our doubled response, whose read_body
    # yields each pre-built NDJSON chunk.
    def stub_streaming(chunks, code: "200")
      response = double("response", code: code)
      allow(response).to receive(:read_body) do |&blk|
        chunks.each { |c| blk.call(c) }
      end
      allow(fake_http).to receive(:request) do |_req, &blk|
        blk.call(response)
      end
    end

    it "yields each `response` chunk and accumulates the final text" do
      stub_streaming([
        '{"model":"llama3","response":"hel","done":false}' + "\n",
        '{"model":"llama3","response":"lo","done":false}' + "\n",
        '{"model":"llama3","response":"","done":true,"prompt_eval_count":7,"eval_count":2}' + "\n"
      ])
      seen = []
      result = provider.invoke(prompt: "p", model: "llama3", max_tokens: 50, stream: true) { |c| seen << c }
      expect(seen).to eq(%w[hel lo])
      expect(result.response_text).to eq("hello")
      expect(result.tokens_in).to eq(7)
      expect(result.tokens_out).to eq(2)
    end

    it "handles a chunk that splits an NDJSON line across reads" do
      stub_streaming([
        '{"model":"llama3","response":"a',
        'b","done":false}' + "\n",
        '{"model":"llama3","done":true,"prompt_eval_count":1,"eval_count":1}' + "\n"
      ])
      result = provider.invoke(prompt: "p", model: "llama3", max_tokens: 5, stream: true)
      expect(result.response_text).to eq("ab")
    end

    it "raises LlmAdapterError on streaming non-200" do
      stub_streaming([], code: "500")
      expect {
        provider.invoke(prompt: "p", model: "m", max_tokens: 1, stream: true)
      }.to raise_error(Hecks::LlmAdapterError, /500/)
    end
  end

  describe "no real network" do
    it "never instantiates Net::HTTP without our stub in place" do
      # If the production code accidentally creates a fresh Net::HTTP
      # outside our stub, this expectation would fail (Net::HTTP.new
      # is the only door to a TCP socket).
      expect(Net::HTTP).to receive(:new).and_return(fake_http)
      ok = double("response", code: "200")
      allow(fake_http).to receive(:request).and_return(ok)
      provider.boot_probe
    end
  end
end
