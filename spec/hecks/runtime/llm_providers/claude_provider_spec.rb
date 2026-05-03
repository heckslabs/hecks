# spec/hecks/runtime/llm_providers/claude_provider_spec.rb
#
# Contract for Hecks::Runtime::LlmProviders::ClaudeProvider. Exercises:
#   - transport selection (CLI default, API when ANTHROPIC_API_KEY set)
#   - boot probe success / failure → degraded? state
#   - CLI invocation : env whitelist, stream-json parsing, token counts
#   - API invocation : SSE parsing, unary JSON parsing
#   - LlmInvocationSkipped raised when degraded
#   - LlmAdapterError raised on transport failure
#
# All I/O is stubbed — Open3 capture3 + Net::HTTP request are doubled
# out, so the spec runs entirely offline (well under the 1 s budget).
$LOAD_PATH.unshift File.expand_path("../../../../../ruby", __dir__)
require "hecks"
require "hecks/runtime"

RSpec.describe Hecks::Runtime::LlmProviders::ClaudeProvider do
  # Helper: build a stream-json payload as the CLI would emit it.
  def stream_json_payload(text_chunks:, input_tokens: 5, output_tokens: 7, model: "claude-sonnet-4")
    events = []
    events << {
      "type" => "message_start",
      "message" => { "model" => model, "usage" => { "input_tokens" => input_tokens } }
    }
    text_chunks.each do |chunk|
      events << { "type" => "content_block_delta", "delta" => { "type" => "text_delta", "text" => chunk } }
    end
    events << { "type" => "message_delta", "usage" => { "output_tokens" => output_tokens } }
    events << { "type" => "message_stop" }
    events.map(&:to_json).join("\n") + "\n"
  end

  # Fake Process::Status that responds to #success? + to_s.
  def ok_status
    status = double("status", success?: true)
    allow(status).to receive(:to_i).and_return(0)
    status
  end

  def failed_status(code = 1)
    status = double("status", success?: false)
    allow(status).to receive(:to_i).and_return(code)
    status
  end

  describe "#transport" do
    it "is :cli by default (no ANTHROPIC_API_KEY)" do
      provider = described_class.new(api_key: nil)
      expect(provider.transport).to eq(:cli)
    end

    it "is :api when ANTHROPIC_API_KEY is set" do
      provider = described_class.new(api_key: "sk-test")
      expect(provider.transport).to eq(:api)
    end

    it "treats empty API key as :cli (Claude Max preference)" do
      provider = described_class.new(api_key: "")
      expect(provider.transport).to eq(:cli)
    end
  end

  describe "#boot_probe (CLI)" do
    let(:provider) { described_class.new(api_key: nil) }

    it "marks healthy when `claude --version` exits 0" do
      expect(Open3).to receive(:capture3).with(
        hash_including("HOME", "PATH"),
        "claude", "--version",
        hash_including(unsetenv_others: true)
      ).and_return(["0.5.0", "", ok_status])
      expect(provider.boot_probe).to be true
      expect(provider.degraded?).to be false
    end

    it "marks degraded when CLI is missing" do
      expect(Open3).to receive(:capture3).and_raise(Errno::ENOENT.new("claude"))
      expect(provider.boot_probe).to be false
      expect(provider.degraded?).to be true
      expect(provider.degraded_reason).to include("claude")
    end

    it "marks degraded when CLI exits non-zero" do
      expect(Open3).to receive(:capture3).and_return(["", "broken", failed_status(1)])
      expect(provider.boot_probe).to be false
      expect(provider.degraded?).to be true
    end
  end

  describe "#invoke when degraded" do
    it "raises LlmInvocationSkipped(reason: 'provider_unavailable')" do
      provider = described_class.new(api_key: nil)
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT.new("claude"))
      provider.boot_probe
      expect {
        provider.invoke(prompt: "hi", model: "claude-sonnet-4", max_tokens: 100)
      }.to raise_error(Hecks::LlmInvocationSkipped) { |e|
        expect(e.reason).to eq("provider_unavailable")
      }
    end
  end

  describe "#invoke (CLI)" do
    let(:provider) { described_class.new(api_key: nil) }

    it "passes the strict env whitelist + unsetenv_others to Open3" do
      payload = stream_json_payload(text_chunks: ["hi"])
      expect(Open3).to receive(:capture3) do |env, bin, *args, **opts|
        expect(env.keys).to contain_exactly("HOME", "PATH")
        expect(bin).to eq("claude")
        expect(opts[:unsetenv_others]).to be true
        expect(opts[:stdin_data]).to eq("hello")
        expect(args).to include("-p", "--output-format", "stream-json", "--model", "claude-sonnet-4")
        [payload, "", ok_status]
      end
      result = provider.invoke(prompt: "hello", model: "claude-sonnet-4", max_tokens: 200)
      expect(result.response_text).to eq("hi")
    end

    it "accumulates text from content_block_delta events" do
      payload = stream_json_payload(text_chunks: ["hello", " ", "world"])
      allow(Open3).to receive(:capture3).and_return([payload, "", ok_status])
      result = provider.invoke(prompt: "p", model: "claude-sonnet-4", max_tokens: 200)
      expect(result.response_text).to eq("hello world")
    end

    it "captures input + output token counts" do
      payload = stream_json_payload(text_chunks: ["hi"], input_tokens: 12, output_tokens: 3)
      allow(Open3).to receive(:capture3).and_return([payload, "", ok_status])
      result = provider.invoke(prompt: "p", model: "claude-sonnet-4", max_tokens: 100)
      expect(result.tokens_in).to eq(12)
      expect(result.tokens_out).to eq(3)
    end

    it "carries model_used from message_start" do
      payload = stream_json_payload(text_chunks: ["x"], model: "claude-3-5-sonnet-20241022")
      allow(Open3).to receive(:capture3).and_return([payload, "", ok_status])
      result = provider.invoke(prompt: "p", model: "claude-sonnet-4", max_tokens: 100)
      expect(result.model_used).to eq("claude-3-5-sonnet-20241022")
    end

    it "yields each text chunk to a block when stream: true" do
      payload = stream_json_payload(text_chunks: ["a", "b", "c"])
      allow(Open3).to receive(:capture3).and_return([payload, "", ok_status])
      seen = []
      result = provider.invoke(prompt: "p", model: "m", max_tokens: 50, stream: true) { |c| seen << c }
      expect(seen).to eq(%w[a b c])
      expect(result.response_text).to eq("abc")
    end

    it "raises LlmAdapterError on non-zero CLI exit" do
      allow(Open3).to receive(:capture3).and_return(["", "auth expired", failed_status(2)])
      expect {
        provider.invoke(prompt: "p", model: "m", max_tokens: 50)
      }.to raise_error(Hecks::LlmAdapterError, /auth expired/)
    end

    it "ignores garbage lines in the stream-json payload" do
      payload = "not json\n" + stream_json_payload(text_chunks: ["ok"]) + "\n"
      allow(Open3).to receive(:capture3).and_return([payload, "", ok_status])
      result = provider.invoke(prompt: "p", model: "m", max_tokens: 50)
      expect(result.response_text).to eq("ok")
    end
  end

  describe "#invoke (API path)" do
    let(:provider) { described_class.new(api_key: "sk-test") }

    let(:fake_unary_response) do
      double("response", code: "200",
        body: {
          "id" => "msg_x",
          "model" => "claude-sonnet-4",
          "content" => [{ "type" => "text", "text" => "hi from api" }],
          "usage" => { "input_tokens" => 11, "output_tokens" => 4 }
        }.to_json
      )
    end

    let(:fake_http) { instance_double(Net::HTTP) }

    before do
      allow(Net::HTTP).to receive(:new).and_return(fake_http)
      allow(fake_http).to receive(:use_ssl=)
    end

    it "POSTs to api.anthropic.com with x-api-key + anthropic-version" do
      seen_req = nil
      allow(fake_http).to receive(:request) do |req|
        seen_req = req
        fake_unary_response
      end
      provider.invoke(prompt: "hi", model: "claude-sonnet-4", max_tokens: 50)
      expect(seen_req["x-api-key"]).to eq("sk-test")
      expect(seen_req["anthropic-version"]).to eq("2023-06-01")
      body = JSON.parse(seen_req.body)
      expect(body["model"]).to eq("claude-sonnet-4")
      expect(body["max_tokens"]).to eq(50)
    end

    it "returns a Result populated from the JSON body (unary)" do
      allow(fake_http).to receive(:request).and_return(fake_unary_response)
      result = provider.invoke(prompt: "hi", model: "claude-sonnet-4", max_tokens: 50)
      expect(result.response_text).to eq("hi from api")
      expect(result.tokens_in).to eq(11)
      expect(result.tokens_out).to eq(4)
      expect(result.model_used).to eq("claude-sonnet-4")
    end

    it "raises LlmAdapterError on non-200 response" do
      bad = double("response", code: "401", body: '{"error":{"type":"authentication_error"}}')
      allow(fake_http).to receive(:request).and_return(bad)
      expect {
        provider.invoke(prompt: "p", model: "m", max_tokens: 1)
      }.to raise_error(Hecks::LlmAdapterError, /401/)
    end
  end

  describe "WebMock-equivalent isolation" do
    it "never opens a real socket during a CLI invoke (Open3 fully stubbed)" do
      provider = described_class.new(api_key: nil)
      allow(Open3).to receive(:capture3).and_return([
        stream_json_payload(text_chunks: ["x"]), "", ok_status
      ])
      # Tripwire : if the provider were to bypass Open3 for any reason,
      # this would fail because TCPSocket is forbidden.
      expect(TCPSocket).not_to receive(:open)
      provider.invoke(prompt: "p", model: "m", max_tokens: 1)
    end
  end
end
