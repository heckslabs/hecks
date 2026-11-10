# frozen_string_literal: true

require "json"
require "time"
require_relative "console_capture"

module Hecks
  module Adapters
    # Where a run's session is before it is answered, and the delivery of an answer to one that is
    # working, for `ClaudeAgents#present` and `#deliver`.
    #
    # It reports what `claude agents` lists and judges nothing: which path an answer takes (deliver
    # or resume) is the bluebook's `AnswerTheSessionWhereItIs` rule. The listing is the source, not
    # the job's state file: a session that ended its turn is listed `idle` while its job still
    # reads `working`, and an idle session runs no hook.
    class SessionPresence
      # @param listing [ClaudeSessionListing] the `claude agents` listing
      # @param jobs [ClaudeJobs] the sessions' job state files
      # @param inbox [SessionInbox] where an answer for a working session waits
      def initialize(listing:, jobs:, inbox:)
        @listing = listing
        @jobs = jobs
        @inbox = inbox
      end

      # @param session [String] the id the run holds
      # @return [Hash{Symbol => Object}] `listed:` whether `claude agents` lists the session,
      #   `status:` and `state:` as it lists them (empty when it does not), and `note:` that in
      #   words
      # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
      def call(session)
        @listing.forget!
        entry = @listing.find(session)
        return { listed: false, status: "", state: "", note: "session #{session} is not listed" } unless entry

        status, state = entry.values_at("status", "state").map(&:to_s)
        { listed: true, status: status, state: state, note: "session #{session} is listed #{status}, #{state}" }
      end

      # Leaves the answer in the session's inbox. A session whose settings carry no inbox hook
      # would never read it, so that is refused by name and nothing is left.
      #
      # @param run [String] the run's key
      # @param session [String] the id the run holds
      # @param answer [String] what the session is told
      # @return [Hash{Symbol => Object}] `queued_at:` when the answer was left, `session:` the id
      # @raise [ConsoleCapture::Failure] when the session carries no inbox hook
      def deliver(run, session, answer)
        raise ConsoleCapture::Failure, unhooked(session) unless hooked?(run, session)

        @inbox.leave(run, answer)
        { queued_at: { value: Time.now.utc.iso8601 }, session: { value: session } }
      end

      private

      def unhooked(session)
        "session #{session} carries no inbox hook, so it cannot be answered while it works; answer it when its turn ends"
      end

      # Whether the settings the session was started with name the run's inbox.
      def hooked?(run, session)
        JSON.generate(@jobs.state(session)["respawnFlags"] || []).include?(@inbox.path(run))
      rescue ConsoleCapture::Failure
        false
      end
    end
  end
end
