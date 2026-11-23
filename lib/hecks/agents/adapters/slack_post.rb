# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    # Turns one Slack message event from the crew channel into a mail spool line, the same shape
    # `.claude/hooks/mail_send.sh` appends. It only translates fields: who the owner is, which names
    # are agents and which channel is the crew room are handed in, never decided here.
    #
    # A post that begins `name:` for a known agent is addressed to it; any other post goes to the
    # default recipient. The owner's Slack ID is sent as `owner` with kind `owner`; anyone else
    # keeps their own name with kind `person`.
    class SlackPost
      # The most bytes one spool line may hold, since only an append under PIPE_BUF is atomic.
      LINE_LIMIT = 4000

      # @param owner [String] the owner's Slack user ID
      # @param channel [String] the Slack channel ID of the crew room
      # @param agents [Array<String>] the names a post may address
      # @param default [String] who an unaddressed post goes to
      # @param names [#call] answers a Slack user ID with the name to send under
      def initialize(owner:, channel:, agents:, default: "orchestrator", names: ->(id) { id })
        @owner = owner
        @channel = channel
        @agents = agents
        @default = default
        @names = names
      end

      # @param event [Hash] a Slack `message` event
      # @return [Hash, nil] the spool line, or nil for a post to ignore: another channel, a bot's
      #   post, an edit or other subtype, or an empty one
      def line(event)
        return nil unless takes?(event)

        recipient, body = address(event["text"].to_s.strip)
        fitted(spool(event, recipient, body))
      end

      private

      def takes?(event)
        event["channel"] == @channel && event["user"].to_s != "" && !event.key?("bot_id") &&
          !event.key?("subtype") && event["text"].to_s.strip != ""
      end

      def address(text)
        name, rest = text.split(":", 2)
        return [@default, text] unless rest && @agents.include?(name.to_s.strip.downcase) && !rest.strip.empty?

        [name.strip.downcase, rest.strip]
      end

      def spool(event, recipient, body)
        owner = event["user"] == @owner
        { message: "slack-#{event.fetch("client_msg_id", event["ts"])}", recipient: recipient,
          sender: owner ? "owner" : @names.call(event["user"]), kind: owner ? "owner" : "person",
          body: body, in_reply_to: "", asker_role: "", source: "slack" }
      end

      def fitted(line)
        line[:body] = line[:body][0, 2000]
        line[:body] = line[:body][0...-1] while JSON.generate(line).bytesize > LINE_LIMIT
        line
      end
    end
  end
end
