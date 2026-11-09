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
    #
    # Listing runs `claude`, and one sweep asks about many runs, so a listing is kept for {TTL}
    # seconds and shared by them. A session the kept listing shows is taken as listed, which errs
    # toward keeping a run. A session it does not show is looked for again in a fresh listing,
    # unless this one was read a moment ago, so a vanished session is never judged on stale news.
    class ClaudeSessionListing
      # Seconds a listing is kept for the sessions it shows.
      TTL = 15

      # Seconds within which a listing is fresh enough to be believed about a session it lacks.
      FRESH = 2

      # @param command [String] the program that lists sessions
      # @param shell [Shell] runs it
      # @param now [#call] answers the time
      def initialize(command, shell: Shell.new, now: -> { Time.now })
        @command = command
        @shell = shell
        @now = now
        @entries = nil
        @read_at = nil
      end

      # @param id [String] the short or the full session id
      # @return [Hash, nil] the session as the listing has it, nil when it is not listed
      # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
      def find(id)
        found = lookup(kept, id)
        return found if found || just_read?

        lookup(read, id)
      end

      # Forgets the kept listing, so the next question reads a fresh one. A caller that has just
      # removed or stopped a session calls it, since the kept listing still shows that session.
      #
      # @return [void]
      def forget!
        @entries = nil
        @read_at = nil
      end

      private

      def just_read? = !age_of_read.nil? && age_of_read < FRESH

      def lookup(entries, id) = entries&.find { |entry| [entry["id"], entry["sessionId"]].include?(id) }

      def kept = (@entries if age_of_read && age_of_read < TTL)

      def age_of_read = (@now.call - @read_at if @read_at)

      def read
        listing = @shell.capture(@command, "agents", "--json", "--all")
        raise ConsoleCapture::Failure, "#{@command} could not list sessions: #{listing.err.strip}" unless listing.ok?

        @read_at = @now.call
        @entries = JSON.parse(listing.out)
      end
    end
  end
end
