require "spec_helper"

RSpec.describe Hecks::AI::LlmClient do
  let(:api_key) { "test-key" }
  subject(:client) { described_class.new(api_key: api_key) }

  describe "#generate_domain" do
    let(:tool_input) do
      {
        domain_name: "Bakery",
        aggregates: [
          {
            name: "Cake",
            attributes: [{ name: "name", type: "String" }],
            commands: [{ name: "CreateCake", attributes: [{ name: "name", type: "String" }] }],
            validations: [{ field: "name", presence: true }]
          }
        ]
      }
    end

    let(:api_response_body) do
      {
        id: "msg_01",
        type: "message",
        role: "assistant",
        content: [
          { type: "tool_use", id: "toolu_01", name: "define_domain", input: tool_input }
        ],
        model: "claude-opus-4-5",
        stop_reason: "tool_use"
      }.to_json
    end

    before do
      stub_http_response(200, api_response_body)
    end

    it "returns the tool input hash from the API response" do
      result = client.generate_domain("a bakery domain with cakes")
      expect(result[:domain_name]).to eq("Bakery")
      expect(result[:aggregates].first[:name]).to eq("Cake")
    end

    context "when the API returns a non-200 status" do
      before { stub_http_response(401, '{"error": "unauthorized"}') }

      it "raises a descriptive error" do
        expect { client.generate_domain("test") }
          .to raise_error(RuntimeError, /Anthropic API error 401/)
      end
    end

    context "when the response contains no tool_use block" do
      let(:no_tool_body) do
        { content: [{ type: "text", text: "here is your domain" }] }.to_json
      end

      before { stub_http_response(200, no_tool_body) }

      it "raises a descriptive error" do
        expect { client.generate_domain("test") }
          .to raise_error(RuntimeError, /No tool_use block/)
      end
    end

    def stub_http_response(code, body)
      response = instance_double(Net::HTTPResponse, code: code.to_s, body: body)
      allow_any_instance_of(Net::HTTP).to receive(:request).and_return(response)
    end
  end
end
