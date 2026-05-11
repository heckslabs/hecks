# Hecks::Extensions::Claude
#
# Claude LLM extension for the chat_agent capability. Supports two
# modes: API (requires api_key + credits) and CLI (uses local claude
# command with your Max/Pro subscription).
#
# World file config:
#   claude do
#     model "sonnet"          # model alias or full name
#     max_tokens 4096         # max response tokens
#     api_key ENV["..."]      # optional — triggers API mode
#   end
#
# When api_key is present, uses the HTTP API directly. Otherwise
# falls back to the local `claude` CLI, which uses your subscription.
#
require_relative "claude/claude_adapter"
require_relative "claude/claude_cli_adapter"

Hecks.describe_extension(:claude,
  description: "Anthropic Claude LLM adapter for chat_agent capability",
  adapter_type: :driven,
  config: {
    api_key:    { required: false, desc: "Anthropic API key (omit to use CLI)" },
    model:      { default: "sonnet", desc: "Claude model name or alias" },
    max_tokens: { default: 4096, desc: "Maximum response tokens" }
  },
  wires_to: :chat_agent)

Hecks.register_extension(:claude) do |_domain_mod, _domain, _runtime|
  next unless defined?(Hecks::Capabilities::ChatAgent)

  world = Hecks.last_world
  config = world&.config_for(:claude) || {}
  model = config[:model] || "sonnet"
  max_tokens = config[:max_tokens] || 4096

  adapter = if config[:api_key] && !config[:api_key].to_s.empty?
    Hecks::Extensions::ClaudeAdapter.new(
      api_key: config[:api_key], model: model, max_tokens: max_tokens
    )
  else
    Hecks::Extensions::ClaudeCliAdapter.new(
      model: model, max_tokens: max_tokens
    )
  end

  Hecks::Capabilities::ChatAgent.register_adapter(:claude, adapter)
end
