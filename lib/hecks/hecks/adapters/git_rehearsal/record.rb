# frozen_string_literal: true

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

        # @param commit [String] the commit rehearsed
        # @param verdict [String] `green` or `red`
        # @param results [Array<Stages::Result>] the stages
        # @return [void]
        def write(commit, verdict, results)
          failed = results.reject(&:passed).map(&:name).join(",")
          File.write(path, "#{commit} #{verdict} #{Time.now.to_i} #{failed}\n")
        end

        # @return [Entry, nil] the last rehearsal, nil when none has run
        def last
          return unless File.file?(path)

          commit, verdict, at, failed = File.read(path).split(" ", 4)
          Entry.new(commit, verdict, Time.at(at.to_i), failed.to_s.strip)
        end

        private

        def path = File.join(read("rev-parse", "--path-format=absolute", "--git-common-dir"), FILE)
      end
    end
  end
end
