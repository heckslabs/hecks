# frozen_string_literal: true

require "json"
require "time"
require "fileutils"

module Hecks
  module Adapters
    # The standing red flag of one repository: a JSON file in its common git directory that exists
    # while main is red. Landing and the push train read it, so every worktree of the
    # repository sees the same flag and a spec's temporary repository never sees the owner's.
    #
    # The file holds the flag id, the main commit and CI run that raised it, the failed jobs, the
    # red Work items, every later red run, who checked in and what they took, and the tip of the
    # last fix landed while the flag stood. Clearing removes the file.
    class RedFlagMarker
      # The marker's file name, in the common git directory.
      FILE = "hecks-red-flag.json"

      # @return [String] the absolute path of the marker file
      attr_reader :path

      # @param git_dir [String] the repository's common git directory
      # @param clock [#call] answers the current Time
      def initialize(git_dir, clock: -> { Time.now })
        @path = File.join(git_dir, FILE)
        @clock = clock
      end

      # @param commit [String] a main commit
      # @return [Boolean] whether the standing flag already holds a red run of that commit
      def recorded?(commit)
        flag = read
        return false unless flag

        flag["commit"] == commit || flag["runs"].to_a.any? { |run| run["commit"] == commit }
      end

      # @return [Hash, nil] the standing flag, or nil when main is not flagged
      def read
        JSON.parse(File.read(@path)) if File.exist?(@path)
      rescue JSON::ParserError
        { "id" => "unreadable", "commit" => "unknown", "runs" => [], "checkins" => [] }
      end

      # Raises the flag, or records another red run on the standing one.
      #
      # @param commit [String] the main commit whose CI run was red
      # @param run [Hash] `ci_run:`, `jobs:`, `work_items:` of that run
      # @return [Array(Symbol, Hash)] `:raised` or `:noted`, and the flag
      def raise!(commit:, run:)
        flag = read
        return [:raised, write(fresh(commit, run))] unless flag

        flag["runs"] << sighting(commit, run)
        [:noted, write(flag)]
      end

      # @param session [String] who checks in
      # @param taking [String] the Work item or cause they take
      # @return [Hash, nil] the flag after the check-in, or nil when none stands
      def check_in!(session:, taking:)
        flag = read
        return unless flag

        flag["checkins"] << { "session" => session, "taking" => taking, "at" => stamp }
        write(flag)
      end

      # Records the main tip a red Work item's fix landed at, so the train may board it.
      #
      # @param tip [String] the commit main points at after the fix landed
      # @param branch [String] the fix's branch
      # @return [Hash, nil] the flag, or nil when none stands
      def fixed!(tip:, branch:)
        flag = read
        return unless flag

        flag["fix_tip"] = tip
        flag["fix_branch"] = branch
        write(flag)
      end

      # Lowers the flag.
      #
      # @return [Hash, nil] the flag that was standing, or nil when none was
      def clear!
        flag = read
        File.delete(@path) if flag
        flag
      end

      private

      def fresh(commit, run)
        { "id" => "flag-#{commit.to_s[0, 10]}", "commit" => commit, "raised_at" => stamp, "runs" => [sighting(commit, run)],
          "checkins" => [] }
      end

      def sighting(commit, run)
        { "commit" => commit, "ci_run" => run[:ci_run].to_s, "jobs" => run[:jobs].to_s,
          "work_items" => run[:work_items].to_s, "at" => stamp }
      end

      def write(flag)
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, JSON.pretty_generate(flag))
        flag
      end

      def stamp = @clock.call.utc.iso8601
    end
  end
end
