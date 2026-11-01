# frozen_string_literal: true

require "fileutils"
require_relative "reading"

module Hecks
  module Adapters
    class GitRehearsal
      # The last rehearsal's result, kept in a file in the repository's common git directory (never
      # committed, shared by every worktree) as `<commit> <green|red> <unix time> <failing stages>`.
      class Record
        include Reading

        # The file in the common git directory.
        FILE = "hecks-push-rehearsal"

        # What the file holds.
        #
        # @!attribute [r] commit
        #   @return [String] the commit rehearsed
        # @!attribute [r] verdict
        #   @return [String] `green` or `red`
        # @!attribute [r] at
        #   @return [Time] when it ended
        # @!attribute [r] failed
        #   @return [String] the stages that failed, comma separated; empty when green
        Entry = Struct.new(:commit, :verdict, :at, :failed)

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        def initialize(git, checkout)
          @git = git
          @checkout = checkout
        end

        # Records a result atomically (a temp file in the same directory, renamed over the record)
        # unless the record holds a newer commit's result. Newer is decided by ancestry
        # (`git merge-base --is-ancestor`), else by committer time. The check and the rename happen
        # under a lock.
        #
        # @param commit [String] the commit rehearsed
        # @param verdict [String] `green` or `red`
        # @param results [Array<Stages::Result>] the stages
        # @return [String] `recorded`, or the newer record kept and how that was decided
        def write(commit, verdict, results)
          failed = results.reject(&:passed).map(&:name).join(",")
          locked do
            kept = newer_kept(commit)
            next kept if kept

            replace("#{commit} #{verdict} #{Time.now.to_i} #{failed}\n")
            "recorded"
          end
        end

        # @return [Entry, nil] the last rehearsal, nil when none has run
        def last
          return unless File.file?(path)

          commit, verdict, at, failed = File.read(path).split(" ", 4)
          Entry.new(commit, verdict, Time.at(at.to_i), failed.to_s.strip)
        end

        private

        def path = File.join(read("rev-parse", "--path-format=absolute", "--git-common-dir"), FILE)

        def locked(&)
          File.open("#{path}.lock", File::RDWR | File::CREAT) do |lock|
            lock.flock(File::LOCK_EX)
            yield
          end
        end

        # Writes the record through a temp file in its directory, so a reader sees the old record or
        # the new one whole.
        def replace(line)
          temp = "#{path}.#{Process.pid}.tmp"
          File.write(temp, line)
          File.rename(temp, path)
        ensure
          FileUtils.rm_f(temp) if temp
        end

        # The recorded result that outranks this commit's, as a sentence; nil when this one wins.
        def newer_kept(commit)
          held = last
          return unless held && held.commit != commit
          return if ancestor?(held.commit, commit)
          return kept(held, commit, "#{short(commit)} is an ancestor of it") if ancestor?(commit, held.commit)
          return unless committed_at(held.commit) > committed_at(commit)

          kept(held, commit, "by commit time #{short(held.commit)} is later (neither descends from the other)")
        end

        def kept(held, commit, why) = "kept the record for #{short(held.commit)}, newer than #{short(commit)}: #{why}"

        def ancestor?(older, newer) = @git.capture("merge-base", "--is-ancestor", older, newer, chdir: @checkout).ok?

        # A commit's committer time; 0 for one this repository does not hold.
        def committed_at(commit)
          result = @git.capture("show", "-s", "--format=%ct", commit, chdir: @checkout)
          result.ok? ? result.out.to_i : 0
        end
      end
    end
  end
end
