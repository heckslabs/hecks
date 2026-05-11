# Hecks::Extensions::ClaudeAdapter
#
# LLM adapter for Anthropic's Claude API. Translates between the generic
# chat agent tool format and the Anthropic Messages API. Uses net/http
# with no external gem dependencies.
#
#   adapter = ClaudeAdapter.new(api_key: "sk-...", model: "claude-sonnet-4-5")
#   response = adapter.chat(messages: [...], tools: [...], system: "You are...")
#   response[:content]     # => "I'll help you order a pizza."
#   response[:tool_calls]  # => [{ id: "tc_1", name: "CreatePizza", arguments: {...} }]
#
require "net/http"
require "json"
require "uri"

module Hecks
  module Extensions
    class ClaudeAdapter
      API_URL = "https://api.anthropic.com/v1/messages"
      API_VERSION = "2023-06-01"

      def initialize(api_key:, model: "claude-sonnet-4-5", max_tokens: 4096)
        @api_key = api_key
        @model = model
        @max_tokens = max_tokens
      end

      # Send a chat request to the Claude API.
      #
      # @param messages [Array<Hash>] conversation messages
      # @param tools [Array<Hash>] tool definitions in generic format
      # @param system [String] system prompt
      # @return [Hash] normalized response { role:, content:, tool_calls: [] }
      def chat(messages:, tools:, system:)
        body = {
          model: @model,
          max_tokens: @max_tokens,
          system: system,
          messages: format_messages(messages),
          tools: format_tools(tools)
        }

        response = post(body)
        normalize_response(response)
      end

      private

      def post(body)
        uri = URI(API_URL)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true

        request = Net::HTTP::Post.new(uri)
        request["x-api-key"] = @api_key
        request["anthropic-version"] = API_VERSION
        request["content-type"] = "application/json"
        request.body = JSON.generate(body)

        response = http.request(request)
        data = JSON.parse(response.body)
        if data["type"] == "error"
          raise "Claude API error: #{data.dig("error", "message") || data.inspect}"
        end
        data
      end

      def format_messages(messages)
        messages.map do |msg|
          if msg[:tool_calls]
            { role: "assistant", content: msg[:tool_calls].map { |tc| format_tool_use(tc) } }
          elsif msg[:role] == "tool"
            { role: "user", content: [{ type: "tool_result", tool_use_id: msg[:tool_call_id], content: msg[:content].to_s }] }
          else
            { role: msg[:role] || msg["role"], content: msg[:content] || msg["content"] }
          end
        end
      end

      def format_tool_use(tc)
        { type: "tool_use", id: tc[:id], name: tc[:name], input: tc[:arguments] }
      end

      def format_tools(tools)
        tools.map do |tool|
          props = tool[:parameters].each_with_object({}) do |p, h|
            h[p[:name]] = { type: p[:type] }
          end
          required = tool[:parameters].select { |p| p[:required] }.map { |p| p[:name] }
          {
            name: tool[:name],
            description: tool[:description],
            input_schema: { type: "object", properties: props, required: required }
          }
        end
      end

      def normalize_response(data)
        content = ""
        tool_calls = []

        (data["content"] || []).each do |block|
          case block["type"]
          when "text"
            content += block["text"]
          when "tool_use"
            tool_calls << {
              id: block["id"],
              name: block["name"],
              arguments: block["input"] || {}
            }
          end
        end

        { role: "assistant", content: content, tool_calls: tool_calls }
      end
    end
  end
end
