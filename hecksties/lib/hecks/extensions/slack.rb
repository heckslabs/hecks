# HecksSlack
#
# Slack webhook extension for Hecks. Subscribes to the domain event bus
# and POSTs a summary of every event to a Slack incoming webhook URL.
#
# Usage:
#   app = Hecks.boot(__dir__) do
#     extend :slack, webhook: ENV["SLACK_URL"]
#   end
#
# Or at runtime:
#   app.extend(:slack, webhook: "https://hooks.slack.com/services/...")
#
require "net/http"
require "uri"
require "json"

Hecks.describe_extension(:slack,
  description: "Slack webhook notifications for domain events",
  config: { webhook: { desc: "Slack incoming webhook URL" } },
  wires_to: :event_bus)

Hecks.register_extension(:slack) do |domain_mod, domain, runtime|
  webhook = domain_mod.respond_to?(:connections) &&
    domain_mod.connections[:sends]&.find { |s| s[:name] == :slack }&.dig(:webhook)

  next unless webhook

  runtime.event_bus.on_any do |event|
    event_name = Hecks::Utils.const_short_name(event)
    occurred = event.respond_to?(:occurred_at) ? event.occurred_at.iso8601 : Time.now.iso8601
    payload = { text: "[#{domain.name}] #{event_name} at #{occurred}" }

    Thread.new do
      uri = URI(webhook)
      Net::HTTP.post(uri, JSON.generate(payload), "Content-Type" => "application/json")
    rescue => e
      warn "[hecks:slack] Failed to post: #{e.message}"
    end
  end
end
