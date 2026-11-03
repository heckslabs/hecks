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

      # @param directory [String, nil] the jobs directory (default `~/.claude/jobs`)
      def initialize(directory: nil)
        @directory = File.expand_path(directory || DIRECTORY)
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
    end
  end
end
