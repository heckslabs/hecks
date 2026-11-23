# frozen_string_literal: true

require "open3"
require "hecks/agents/adapters/slack_listener"
require "hecks/agents/adapters/slack_socket"

module Hecks
  module Adapters
    # The `RoomHearing` port's adapter for `CrewRoom`: answers `Hear` by opening the Slack
    # Socket Mode connection and appending each crew-room post to the mail spool until it closes.
    #
    # The app token, the owner's Slack user ID and the room's channel ID are read once, at
    # start, with `op read` from the `op://` references in `slack_listener.env`; no value is
    # kept in a file.
    class SlackRoom
      # The references file beside this adapter.
      REFERENCES = File.expand_path("slack_listener.env", __dir__)

      # A line of the references file that holds no reference: a comment or a blank.
      SKIPPED = /\A\s*(#|\z)/

      # Raised when a reference cannot be read with `op`.
      class Unreadable < StandardError; end

      # The agents a post may be addressed to by name when the settings name none.
      AGENTS = %w[orchestrator scrum-master architect reviewer coder].freeze

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `agents:` names, `spool:` path, `reader:` answers an
      #   `op://` reference
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @settings = settings
      end

      # @param room [Hash] the room asking, `{ value: }`
      # @return [Hash{Symbol => Hash}] `room:` passed back once the connection closes
      # @raise [Unreadable] when a reference cannot be read or Slack refuses the token
      def hear(room:, **)
        secrets = references.transform_values { |ref| read(ref) }
        post = SlackPost.new(owner: secrets["SLACK_OWNER_ID"], channel: secrets["SLACK_CREW_CHANNEL"],
                             agents: @settings.fetch(:agents, AGENTS))
        socket = @settings[:socket] || SlackSocket.open(secrets["SLACK_APP_TOKEN"])
        SlackListener.new(socket: socket, post: post, **spool).run
        { room: room }
      end

      private

      def spool = @settings[:spool] ? { spool: @settings[:spool] } : {}

      def references
        File.readlines(REFERENCES, chomp: true).grep_v(SKIPPED).to_h { |line| line.split("=", 2) }
      end

      def read(reference)
        return @settings[:reader].call(reference) if @settings[:reader]

        out, status = Open3.capture2("op", "read", reference)
        raise Unreadable, "op could not read #{reference}" unless status.success?

        out.strip
      end
    end
  end
end
