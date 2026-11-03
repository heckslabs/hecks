# frozen_string_literal: true

require "fileutils"

module Hecks
  module Adapters
    # The assigned pusher of one repository: a one-line file in its common git directory holding the
    # session id that alone may board the push train. Every worktree of the repository sees the same
    # file, and a spec's temporary repository never sees the owner's. No file means no lock.
    #
    # A session's identity is the job id: the basename of `CLAUDE_JOB_DIR` (`~/.claude/jobs/<id>`),
    # which the harness gives each session's processes. The lock guards mistakes: every session runs
    # as the same user on the same machine, so it does not stop a hostile one. `.githooks/pre-push`
    # reads the same file.
    class PusherMarker
      # The marker's file name, in the common git directory.
      FILE = "hecks-pusher"

      # @param env [Hash] the environment the caller's identity is read from
      # @return [String, nil] the session id of the caller, nil outside a session
      def self.caller_id(env = ENV)
        job = env["CLAUDE_JOB_DIR"].to_s
        job.empty? ? nil : File.basename(job)
      end

      # @param git_dir [String] the repository's common git directory
      def initialize(git_dir)
        @path = File.join(git_dir, FILE)
      end

      # @return [String, nil] the assigned pusher's session id, nil when none is assigned
      def read
        return unless File.exist?(@path)

        line = File.foreach(@path).first
        line.to_s.strip
      end

      # Assigns the pusher, replacing the one before it.
      #
      # @param session [String] the session id
      # @return [String] the session id
      def assign!(session)
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, "#{session}\n")
        session
      end
    end
  end
end
