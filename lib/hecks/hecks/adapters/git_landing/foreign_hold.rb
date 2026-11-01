# frozen_string_literal: true

require "json"
require "open3"

module Hecks
  module Adapters
    class GitLanding
      # A landing in flight that holds no ticket: the shell lock directory old briefs make with
      # `mkdir`, and the claim file landers of an older build write.
      #
      # The head of the line waits for either to go. A directory has no wake-up event, so this is
      # the
      # one place a wait looks again on a timer. A shell lock that one of the caller's own ancestor
      # processes names on its command line is the caller's, so it never blocks the call that
      # holds it.
      class ForeignHold
        # Seconds between looks at the lock.
        LOOK = 2

        # The shell lock directories that guard landings in a repository: the one the world names,
        # and
        # the job's own `land.lock`, which guards only the repository this code runs from.
        #
        # @param git_dir [String] the main checkout's git directory of the repository being landed
        #   in
        # @param named [String, nil] the world's `shell_lock`
        # @return [Array<String>] the directories to honour
        def self.locks(git_dir, named)
          job = ENV.fetch("CLAUDE_JOB_DIR", "")
          own = File.join(job, "tmp", "land.lock") if !job.empty? && home?(git_dir)
          [named, own].compact
        end

        # @return [Boolean] whether a git directory is the repository this code is checked out from
        def self.home?(git_dir)
          out, status = Open3.capture2("git", "rev-parse", "--path-format=absolute", "--git-common-dir", chdir: __dir__)
          status.success? && File.realpath(out.strip) == File.realpath(git_dir)
        rescue SystemCallError
          false
        end

        # @param legacy [String] the claim file the front ticket feeds
        # @param locks [Array<String>] shell lock directories
        # @param stale [Numeric] seconds after which either is taken to be abandoned
        # @param mine [#call] answers whether a lock path is the caller's own
        def initialize(legacy, locks:, stale:, mine: method(:ancestor_names?))
          @legacy = legacy
          @locks = locks
          @stale = stale
          @mine = mine
        end

        # @param token [String] the name of the caller's own ticket, whose claim file it fed itself
        # @return [String, nil] a sentence naming what holds the landing, nil when nothing does
        def holder(token)
          lock = @locks.find { |path| fresh?(path) && !@mine.call(path) }
          return "the shell lock #{lock}" if lock

          claim = fresh_claim(token)
          "#{claim["branch"]}, landing by an older build" if claim
        end

        # Looks every few seconds until nothing holds the landing, or the budget runs out.
        #
        # @param token [String] the caller's ticket
        # @param budget [#call] seconds the caller may still wait
        # @param say [#call] told what is being waited for, once
        # @return [Boolean] false when the budget ran out first
        def clears_within?(token, budget, say)
          said = nil
          while (held = holder(token))
            return false if budget.call <= 0

            say.call("waiting for #{held}") unless said == held
            said = held
            sleep([LOOK, budget.call].min)
          end
          true
        end

        private

        def fresh?(path) = File.exist?(path) && Time.now - File.mtime(path) < @stale

        def fresh_claim(token)
          return unless fresh?(@legacy)

          claim = JSON.parse(File.read(@legacy))
          claim unless claim["token"] == token
        rescue JSON::ParserError
          nil
        end

        # Whether a process above this one has the path on its command line.
        def ancestor_names?(path)
          pid = Process.ppid
          40.times do
            out, = Open3.capture2("ps", "-o", "ppid=,command=", "-p", pid.to_s)
            parent, command = out.strip.split(" ", 2)
            return true if command.to_s.include?(path)
            return false if parent.to_i <= 1

            pid = parent.to_i
          end
          false
        end
      end
    end
  end
end
