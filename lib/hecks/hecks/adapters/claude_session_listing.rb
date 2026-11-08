# frozen_string_literal: true

require "json"
require_relative "shell"
require_relative "console_capture"

module Hecks
  module Adapters
    # The background sessions `claude agents --json --all` lists, looked up by the short id
    # `claude --bg` prints or by the full session id.
    #
    # A session `claude rm` deleted is not listed; one that is stopped, done or failed still is.
    class ClaudeSessionListing
      # @param command [String] the program that lists sessions
      # @param shell [Shell] runs it
      def initialize(command, shell: Shell.new)
        @command = command
        @shell = shell
      end

      # @param id [String] the short or the full session id
      # @return [Hash, nil] the session as the listing has it, nil when it is not listed
      # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
      def find(id)
        entries.find { |entry| [entry["id"], entry["sessionId"]].include?(id) }
      end

      private

      def entries
        listing = @shell.capture(@command, "agents", "--json", "--all")
        raise ConsoleCapture::Failure, "#{@command} could not list sessions: #{listing.err.strip}" unless listing.ok?

        JSON.parse(listing.out)
      end
    end
  end
end
