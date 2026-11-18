# frozen_string_literal: true

require "json"
require "time"
require_relative "console_capture"

module Hecks
  module Adapters
    # The state a background session's job keeps in `~/.claude/jobs/<session>/state.json`: the
    # `state` it is in (working, blocked, done, failed, stopped) and the `detail` it gave, such as
    # the question a blocked session waits on or why a failed one stopped.
    #
    # It reads and judges nothing: which states are new, and which mean a session ended, are the
    # bluebook's.
    class ClaudeJobs
      # Where the jobs are kept unless a setting names another directory.
      DIRECTORY = "~/.claude/jobs"

      # Seconds a woken session is given to stop reading `stopped`.
      WAKE_PATIENCE = 10

      # The file in the jobs directory that names the sessions a person pinned.
      PINS = "pins.json"

      # @param settings [Hash] an adapter's settings: `jobs:` the jobs directory and
      #   `wake_patience:` the seconds a woken session is given, both optional
      # @return [ClaudeJobs] the jobs those settings name
      def self.from(settings)
        new(directory: settings[:jobs], wake_patience: settings.fetch(:wake_patience, WAKE_PATIENCE))
      end

      # @param directory [String, nil] the jobs directory (default `~/.claude/jobs`)
      # @param wake_patience [Numeric] seconds a woken session is given to stop reading `stopped`
      # @param pause [Numeric] seconds between two readings while it waits
      def initialize(directory: nil, wake_patience: WAKE_PATIENCE, pause: 0.25)
        @directory = File.expand_path(directory || DIRECTORY)
        @wake_patience = wake_patience
        @pause = pause
      end

      # The tail of what the session wrote last: the `text` of the job's last timeline entry, which
      # the state file's summary does not carry.
      #
      # @param session [String] the session's id, which names its job's directory
      # @return [String] that text, or empty when the job keeps no timeline or it cannot be read
      def closing(session)
        path = File.join(@directory, session.to_s, "timeline.jsonl")
        return "" unless File.file?(path)

        JSON.parse(File.readlines(path).last.to_s)["text"].to_s
      rescue JSON::ParserError
        ""
      end

      # @param session [String] the session's id, which names its job's directory
      # @return [Hash{String => Object}] the job's state file, parsed
      # @raise [ConsoleCapture::Failure] when the session names no job, or its state cannot be read
      def state(session)
        path = File.join(@directory, session.to_s, "state.json")
        raise ConsoleCapture::Failure, "no job state at #{path}" if session.to_s.empty? || !File.file?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError => e
        raise ConsoleCapture::Failure, "the job state at #{path} cannot be read: #{e.message}"
      end

      # Waits while a session that was just woken still reads `stopped`: its state file keeps
      # the stop until the woken session writes its own state. Any other state ends the wait, and
      # so do a job that cannot be read, as a copy's is until it writes one, and the patience.
      #
      # @param resumed [Hash] what the resume answered: `session:` the id the run follows
      # @return [Hash] the same answer, once the wait is over
      def woken(resumed)
        session = resumed[:session]
        session = session[:value] if session.is_a?(Hash)
        deadline = Time.now + @wake_patience
        sleep(@pause) while stopped?(session) && Time.now < deadline
        resumed
      end

      # @param job [Hash{String => Object}] the job's state file, parsed
      # @param session [String] the session's id
      # @param now [Time] the time to count to
      # @return [Hash{Symbol => Object}] `blocked_minutes:` ({#blocked_minutes}) and `pin_listed:`
      #   ({#pinned?})
      def waiting(job, session, now) = { blocked_minutes: blocked_minutes(job, now), pin_listed: pinned?(session) }

      # Whole minutes since the job's state file was last written (`updatedAt`), for a job that
      # reads blocked. The stamp stands for when the block began: anything that rewrites the file
      # while the job is blocked starts the count again, so a helper is ended later, never sooner.
      #
      # @param job [Hash{String => Object}] the job's state file, parsed
      # @param now [Time] the time to count to
      # @return [Integer] those minutes; 0 for a job not blocked or a stamp that cannot be read
      def blocked_minutes(job, now)
        return 0 unless job["state"].to_s == "blocked"

        ((now - Time.iso8601(job["updatedAt"].to_s)) / 60).floor
      rescue ArgumentError
        0
      end

      # Whether the jobs directory's `pins.json` (a JSON array of job ids, the eight-character
      # prefix of a session's id) names the session.
      #
      # @param session [String] the session's id
      # @return [Boolean] true when it names the session or the pins cannot be read; false when
      #   there is no pins file
      def pinned?(session)
        path = File.join(@directory, PINS)
        return false unless File.file?(path)

        ids = Array(JSON.parse(File.read(path))).map(&:to_s)
        ids.include?(session.to_s) || ids.include?(session.to_s[0, 8])
      rescue JSON::ParserError, SystemCallError
        true
      end

      private

      def stopped?(session)
        state(session)["state"].to_s == "stopped"
      rescue ConsoleCapture::Failure
        false
      end
    end
  end
end
