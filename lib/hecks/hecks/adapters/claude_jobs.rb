# frozen_string_literal: true

require "json"
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

      private

      def stopped?(session)
        state(session)["state"].to_s == "stopped"
      rescue ConsoleCapture::Failure
        false
      end
    end
  end
end
