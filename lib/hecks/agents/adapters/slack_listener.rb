# frozen_string_literal: true

require "json"
require "fileutils"
require "hecks/agents/adapters/slack_post"

module Hecks
  module Adapters
    # Reads Slack Socket Mode envelopes from a socket, acknowledges each, and appends the crew-room
    # posts among them to the mail spool as `.claude/hooks/mail_send.sh` does: one JSON line, no
    # domain booted. It holds no state a restart would lose: a replayed post carries the same
    # message key, which the spool's ingest refuses.
    #
    # The socket answers `read` with the next text frame (nil when closed) and takes `write`.
    class SlackListener
      # Where a send appends, under the dev directory, when no path is named.
      DEFAULT_SPOOL = "~/.claude/hecks-dev/mail/spool.jsonl"

      # @param socket [#read, #write] the Socket Mode connection
      # @param post [SlackPost] turns a Slack event into a spool line
      # @param spool [String] the spool file to append to
      def initialize(socket:, post:, spool: DEFAULT_SPOOL)
        @socket = socket
        @post = post
        @spool = File.expand_path(spool)
        @seen = {}
      end

      # Handles envelopes until the socket closes.
      # @return [Integer] how many lines were appended
      def run
        while (frame = @socket.read)
          handle(JSON.parse(frame))
        end
        @seen.size
      end

      private

      def handle(envelope)
        @socket.write(JSON.generate(envelope_id: envelope["envelope_id"])) if envelope["envelope_id"]
        event = envelope.dig("payload", "event")
        return unless envelope["type"] == "events_api" && event.is_a?(Hash)

        line = @post.line(event)
        append(line) if line && !@seen.key?(line[:message])
      end

      def append(line)
        @seen[line[:message]] = true
        FileUtils.mkdir_p(File.dirname(@spool))
        File.open(@spool, "a") { |file| file.write("#{JSON.generate(line)}\n") }
      end
    end
  end
end
