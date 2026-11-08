# frozen_string_literal: true

require "json"
require "time"
require_relative "cache"

module Hecks
  module Adapters
    # The `Git` port's adapter: where local main stands against `origin/main`, what the push
    # train's copy last pushed, and whether `stable` has caught up with main. It reads refs and
    # never fetches, so it writes nothing, not even a remote-tracking ref.
    class PipelineGit
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `git:` stands in for the program (a callable taking a directory
      #   and the arguments, answering standard output), `train:` for the train's checkout,
      #   `ttl:` for how long a read is kept
      # @param root [String, nil] the checkout whose main is read
      def initialize(aggregate: nil, settings: {}, root: nil)
        @root = root || Dir.pwd
        @git = settings[:git] || ->(dir, *args) { PipelineBoard::Probe.run("git", "-C", dir, *args) }
        @train = settings.fetch(:train) { File.join(Dir.home, ".claude", "hecks-train") }
        @cache = PipelineBoard::Cache.new(ttl: settings.fetch(:ttl, 15))
      end

      # @return [Hash] `ahead`, `behind` (local main against origin/main), `dirty` (changed files in
      #   this checkout), `sha`, `gate` (`green` when the last finish gated this very commit, else
      #   `unknown`) and `changes` (the subjects of the commits on main that origin/main lacks)
      # @raise [PipelineBoard::Unavailable] when git cannot answer
      def local_main
        behind, ahead = ask(@root, "rev-list", "--left-right", "--count", "origin/main...main").split.map(&:to_i)
        { sha: short("main"), ahead: ahead, behind: behind, oldest_unpushed: oldest_unpushed,
          dirty: ask(@root, "status", "--porcelain").lines.size, gate: gate_verdict, changes: changes }
      end

      # @return [Array<String>] what landed on main since origin/main, newest first, at most eight
      def changes = ask(@root, "log", "--first-parent", "-n", "8", "--format=%s", "origin/main..main").lines.map(&:strip)

      # @return [Hash] the commit the train's checkout stands on: `sha`, `at`, and `pushed`
      #   (whether origin/main holds it)
      # @raise [PipelineBoard::Unavailable] when the train's checkout cannot be read
      def train
        sha, at = ask(@train, "log", "-1", "--format=%h %cI").split
        { sha: sha, at: at, pushed: contains?("origin/main", sha) }
      end

      # @return [String, nil] when the oldest commit on local main that origin/main lacks was made
      def oldest_unpushed = ask(@root, "log", "--format=%cI", "origin/main..main").lines.last&.strip

      # @param shas [Array<String>] commits to date
      # @return [Hash{String => String}] each known commit's short sha with when it was made
      def commit_times(shas)
        dated = ask(@root, "log", "-n", "600", "--format=%H %cI", "origin/main").lines.to_h(&:split)
        shas.filter_map { |sha| (full = dated.keys.find { |key| key.start_with?(sha) }) && [sha, dated[full]] }.to_h
      end

      # The standing red flag of the repository, as its marker file holds it, or nil when main is
      # not flagged.
      #
      # @return [Hash, nil] the flag: id, commit, raised_at, runs and checkins
      def red_flag
        common = ask(@root, "rev-parse", "--path-format=absolute", "--git-common-dir").strip
        path = File.join(common, "hecks-red-flag.json")
        JSON.parse(File.read(path)) if File.exist?(path)
      end

      # @return [Hash] `behind`, the commits on origin/main that stable lacks, and `sha`
      # @raise [PipelineBoard::Unavailable] when git cannot answer
      def stable
        { sha: short("origin/stable"), behind: ask(@root, "rev-list", "--count", "origin/stable..origin/main").to_i }
      end

      private

      # `green` only when the finish marker names the commit main stands on now.
      def gate_verdict
        common = ask(@root, "rev-parse", "--path-format=absolute", "--git-common-dir").strip
        path = File.join(common, "hecks-local-main-gate.json")
        marker = JSON.parse(File.read(path)) if File.exist?(path)
        marker && ask(@root, "rev-parse", "main").strip == marker["sha"] ? marker["verdict"] : "unknown"
      rescue JSON::ParserError
        "unknown"
      end

      def short(ref) = ask(@root, "rev-parse", "--short", ref).strip

      def contains?(ref, sha)
        ask(@root, "merge-base", "--is-ancestor", sha, ref)
        true
      rescue PipelineBoard::Unavailable
        false
      end

      def ask(dir, *args) = @cache.fetch([dir, *args]) { @git.call(dir, *args) }
    end
  end
end
