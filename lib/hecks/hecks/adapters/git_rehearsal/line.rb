# frozen_string_literal: true

require "fileutils"
require_relative "reading"

module Hecks
  module Adapters
    class GitRehearsal
      # The line rehearsals of one repository wait in, which is a line of one: at most one rehearsal
      # runs per repository, and every land that arrives meanwhile is folded into a single pending
      # mark, so the running rehearsal runs once more for the latest commit instead of N queued
      # runs.
      #
      # The running rehearsal holds a non-blocking `flock` (released by the system if the process is
      # killed) on a file in the repository's common git directory. The pending mark is a file
      # beside it, replaced atomically; it holds the branch and the commit.
      class Line
        include Reading

        # The files in the common git directory.
        RUNNING = "hecks-push-rehearsal.running"
        PENDING = "hecks-push-rehearsal.pending"

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param scope [String] each scope has its own line, so quick runs alongside full
        def initialize(git, checkout, scope: "full")
          @git = git
          @checkout = checkout
          @suffix = scope == "quick" ? ".quick" : ""
        end

        # Runs the block as the repository's one running rehearsal.
        #
        # @yield [] holding the lock
        # @return [Object, Symbol] the block's value, or `:busy` (the block not run) when another
        #   rehearsal is running
        def running
          File.open(path(RUNNING), File::RDWR | File::CREAT) do |lock|
            return :busy unless lock.flock(File::LOCK_EX | File::LOCK_NB)

            yield
          end
        end

        # Asks the running rehearsal to run once more, for the latest commit of the branch.
        #
        # @param branch [String] the branch to rehearse
        # @param commit [String] the commit that landed, named in the mark
        # @return [String] the mark, `pending: rehearse <sha>`
        def mark(branch, commit)
          temp = "#{path(PENDING)}.#{Process.pid}.tmp"
          File.write(temp, "#{branch} #{commit}\n")
          File.rename(temp, path(PENDING))
          "pending: rehearse #{short(commit)}"
        end

        # Takes the pending mark, if any, leaving none: a land arriving after this marks anew.
        #
        # @return [String, nil] the branch to rehearse again, nil when nothing is pending
        def take
          file = path(PENDING)
          return unless File.file?(file)

          branch = File.read(file).split.first
          FileUtils.rm_f(file)
          branch
        end

        private

        def path(name) = File.join(read("rev-parse", "--path-format=absolute", "--git-common-dir"), "#{name}#{@suffix}")
      end
    end
  end
end
