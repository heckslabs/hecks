# frozen_string_literal: true

require "hecks/hecks/adapters/console_capture"
require "hecks/hecks/adapters/claude_resolving_shell"
require "hecks/agents/adapters/fleet_control/listing"

module Hecks
  module Adapters
    # The `HandRunWatching` port's adapter for `HandRun`: reads the sessions `claude agents` lists,
    # once for a beat, and answers what it sees of a hand run's session and of its run key.
    #
    # It reads and judges nothing: a listed state is answered as listed, and a session that is not
    # listed is answered `unlisted`. The bluebook decides which states are a loss.
    class HandRunWatch
      # The state answered for a session `claude agents` does not list.
      UNLISTED = "unlisted"

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `shell:` runs `claude`
      # @param root [String, nil] unused
      # @param listing [#call, nil] stand-in: answers the listed sessions, as the CLI prints them
      def initialize(aggregate: nil, settings: {}, root: nil, listing: nil)
        @listing = listing || -> { FleetControl::Listing.new(settings[:shell] || ClaudeResolvingShell.new).entries }
      end

      # @param run [Hash] the run key, passed back
      # @param session [Hash] the registered session
      # @return [Hash{Symbol => Object}] `state:` the session's listed state, or `unlisted`
      # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
      def read_session(run:, session:, role:, checkout: nil, **)
        entry = entries.find { |listed| ids(listed).any? { |id| id.start_with?(plain(session)) } }
        { run: run, session: session, role: role, checkout: checkout, state: entry ? entry["state"].to_s : UNLISTED }
      end

      # @param run [Hash] the run key, which a resumed session is listed under
      # @param session [Hash] the lost session
      # @return [Hash{Symbol => Object}] `found:` the other session listed under the key and
      #   `state:` its state, `unlisted` when none is
      # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
      def read_run_key(run:, session:, role:, checkout: nil, **)
        entry = entries.find { |listed| listed["name"].to_s == plain(run) && !ids(listed).include?(plain(session)) }
        { run: run, session: session, role: role, checkout: checkout, found: { value: entry ? full_id(entry) : "" },
          state: entry ? entry["state"].to_s : UNLISTED }
      end

      private

      def entries = @listing.call

      def ids(entry) = [entry["id"], entry["sessionId"]].compact.map(&:to_s).reject(&:empty?)

      def full_id(entry) = (entry.key?("sessionId") ? entry["sessionId"] : entry["id"]).to_s

      def plain(argument) = argument.is_a?(Hash) ? argument[:value].to_s : argument.to_s
    end
  end
end
