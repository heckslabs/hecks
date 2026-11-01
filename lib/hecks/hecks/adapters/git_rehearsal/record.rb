# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "reading"

module Hecks
  module Adapters
    class GitRehearsal
      # The last rehearsal's result per scope, kept in files in the repository's common git
      # directory
      # (never committed, shared by every worktree) as `<commit> <green|red> <unix time> <failing
      # stages>`. The `full` scope's file is `hecks-push-rehearsal` (the only file before scopes
      # existed, so an old record reads as `full`); the `quick` scope's is
      # `hecks-push-rehearsal.quick`.
      class Record
        include Reading

        # The file in the common git directory.
        FILE = "hecks-push-rehearsal"

        # The file beside it counting, per spec file, the rehearsals it was flaky in: a JSON map.
        FLAKES = "#{FILE}.flakes".freeze

        # The `quick` scope's file.
        QUICK = "#{FILE}.quick".freeze

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
        # @param scope [String] `full` or `quick`: which scope's record this is
        # @return [String] `recorded`, or the newer record kept and how that was decided
        def write(commit, verdict, results, scope: "full")
          failed = results.reject(&:passed).map(&:name).join(",")
          locked(scope) do
            kept = newer_kept(commit, scope)
            next kept if kept

            replace("#{commit} #{verdict} #{Time.now.to_i} #{failed}\n", path(scope))
            "recorded"
          end
        end

        # Counts one more rehearsal in which each spec file was flaky (failed in a batch, passed
        # alone). The read, the increment and the rename happen under the record's lock, so
        # concurrent rehearsals lose no count.
        #
        # @param specs [Array<String>] the flaky spec files
        # @return [Hash{String => Integer}] each of them with the rehearsals it has been flaky in
        def count_flakes(specs)
          locked do
            counts = flake_counts
            specs.each { |spec| counts[spec] = counts.fetch(spec, 0) + 1 }
            replace(JSON.generate(counts), flakes_path) unless specs.empty?
            counts.slice(*specs)
          end
        end

        # @return [Hash{String => Integer}] the rehearsals each spec file has been flaky in
        def flake_counts
          JSON.parse(File.read(flakes_path))
        rescue Errno::ENOENT, JSON::ParserError
          {}
        end

        # @param scope [String] `full` or `quick`
        # @return [Entry, nil] the last rehearsal of that scope, nil when none has run
        def last(scope = "full")
          return unless File.file?(path(scope))

          commit, verdict, at, failed = File.read(path(scope)).split(" ", 4)
          Entry.new(commit, verdict, Time.at(at.to_i), failed.to_s.strip)
        end

        private

        def path(scope = "full") = File.join(common_dir, scope == "quick" ? QUICK : FILE)

        def flakes_path = File.join(common_dir, FLAKES)

        def common_dir = read("rev-parse", "--path-format=absolute", "--git-common-dir")

        def locked(scope = "full", &)
          File.open("#{path(scope)}.lock", File::RDWR | File::CREAT) do |lock|
            lock.flock(File::LOCK_EX)
            yield
          end
        end

        # Writes the record through a temp file in its directory, so a reader sees the old record or
        # the new one whole.
        def replace(line, target = path)
          temp = "#{target}.#{Process.pid}.tmp"
          File.write(temp, line)
          File.rename(temp, target)
        ensure
          FileUtils.rm_f(temp) if temp
        end

        # The recorded result that outranks this commit's, as a sentence; nil when this one wins.
        def newer_kept(commit, scope)
          held = last(scope)
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
