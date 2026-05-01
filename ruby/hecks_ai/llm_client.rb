# Hecks::AI::LlmClient
#
# Minimal net/http client for the Anthropic Messages API.
# Uses tool_use to force structured JSON output matching a domain schema —
# no free-form text generation, no parsing failures.
#
# Zero new gem dependencies: uses only net/http, json, and uri from stdlib.
#
#   client = Hecks::AI::LlmClient.new(api_key: ENV["ANTHROPIC_API_KEY"])
#   result = client.generate_domain("banking system with accounts and loans")
#   result[:domain_name]   # => "Banking"
#   result[:aggregates]    # => [{ name: "Account", attributes: [...], commands: [...] }, ...]
#
module Hecks
  module AI
    class LlmClient
      require "net/http"
      require "uri"
      require "json"

      API_URL  = "https://api.anthropic.com/v1/messages"
      MODEL    = "claude-opus-4-5"
      MAX_TOKENS = 4096

      # Initializes the client with an Anthropic API key.
      #
      # @param api_key [String] Anthropic API key
      # @param model [String] model ID override (default: claude-opus-4-5)
      def initialize(api_key:, model: MODEL)
        @api_key = api_key
        @model   = model
      end

      # Send a domain description to the LLM and return structured domain JSON.
      #
      # Uses tool_use to force the model to return structured JSON matching the
      # Hecks domain schema. Returns the parsed tool input hash on success.
      #
      # @param description [String] natural language domain description
      # @return [Hash] structured domain definition with :domain_name and :aggregates
      # @raise [RuntimeError] on HTTP errors or unexpected API responses
      def generate_domain(description)
        body = build_request(description)
        response = post(body)
        extract_tool_result(response)
      end

      private

      def build_request(description)
        {
          model: @model,
          max_tokens: MAX_TOKENS,
          system: Hecks::AI::Prompts::DomainGeneration::SYSTEM_PROMPT,
          tools: [Hecks::AI::Prompts::DomainGeneration::TOOL_SCHEMA],
          tool_choice: { type: "tool", name: "define_domain" },
          messages: [
            { role: "user", content: description }
          ]
        }
      end

      def post(body)
        uri  = URI.parse(API_URL)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true

        request = Net::HTTP::Post.new(uri.path)
        request["x-api-key"]         = @api_key
        request["anthropic-version"]  = "2023-06-01"
        request["content-type"]       = "application/json"
        request.body = JSON.generate(body)

        response = http.request(request)
        raise "Anthropic API error #{response.code}: #{response.body}" unless response.code == "200"

        JSON.parse(response.body, symbolize_names: true)
      end

      def extract_tool_result(response)
        content = response[:content] || []
        tool_use = content.find { |block| block[:type] == "tool_use" }
        raise "No tool_use block in response. Full response: #{response.inspect}" unless tool_use

        input = tool_use[:input]
        raise "Empty tool input in response" unless input

        input
      end
    end
  end
end
