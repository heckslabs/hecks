# frozen_string_literal: true

require "json"
require "time"
require "fileutils"

module Hecks
  module Adapters
    # The candidate of one repository: a JSON file in its common git directory that records the
    # commit the push train last pushed to the candidate ref, the base it was built on, how many
    # commits it carries, and where it stands (`queued`, `green`, `red`, `promoted`, `rejected`).
    # The train, the candidate commands and the pre-push hook read it from every worktree, and a
    # spec's temporary repository never sees the owner's.
    #
    # The file is a record, not the truth: the remote's candidate ref and main say where the
    # candidate is, and an observation brings the file up to them.
    class CandidateMarker
      # The marker's file name, in the common git directory.
      FILE = "hecks-candidate.json"

      # The states in which a candidate is still in flight: nothing else boards until it ends.
      IN_FLIGHT = %w[queued green red].freeze

      # @param git_dir [String] the repository's common git directory
      # @param clock [#call] answers the current Time
      def initialize(git_dir, clock: -> { Time.now })
        @path = File.join(git_dir, FILE)
        @clock = clock
      end

      # @return [Hash, nil] the recorded candidate, or nil when none was recorded
      def read
        JSON.parse(File.read(@path)) if File.exist?(@path)
      rescue JSON::ParserError
        { "sha" => "unreadable", "state" => "red", "commits" => 0 }
      end

      # @return [Boolean] whether the recorded candidate is still in flight
      def in_flight?
        candidate = read
        !candidate.nil? && IN_FLIGHT.include?(candidate["state"].to_s)
      end

      # Records a new candidate as queued, replacing whatever stood before.
      #
      # @param sha [String] the commit pushed to the candidate ref
      # @param base [String] the commit of the remote's main it was built on
      # @param commits [Integer] how many commits it carries beyond the base
      # @return [Hash] the candidate
      def queue!(sha:, base:, commits:)
        write("sha" => sha, "base" => base, "commits" => commits, "state" => "queued", "queued_at" => stamp)
      end

      # Moves the recorded candidate to a state, keeping the facts given with it.
      #
      # @param state [String] `green`, `red`, `promoted` or `rejected`
      # @param facts [Hash{String => String}] `ci_run`, `jobs`, `branch`, `via`
      # @return [Hash, nil] the candidate, or nil when none was recorded
      def note!(state, **facts)
        candidate = read
        return unless candidate

        write(candidate.merge(facts.transform_keys(&:to_s)).merge("state" => state, "#{state}_at" => stamp))
      end

      private

      def write(candidate)
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, JSON.pretty_generate(candidate))
        candidate
      end

      def stamp = @clock.call.utc.iso8601
    end
  end
end
