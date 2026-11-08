# frozen_string_literal: true

require "json"
require "time"

module Hecks
  module Adapters
    class GitLanding
      # The record that the quick gate passed on the commit local `main` names after a finish.
      #
      # It is one JSON file in the repository's git directory, read by the pipeline board to say
      # whether the tree the owner is about to test was gated.
      module GateMarker
        # The file name, in the git directory.
        FILE = "hecks-local-main-gate.json"

        # @param common_dir [String] the repository's common git directory
        # @param sha [String] the commit main names after the landing
        # @return [String] the path written
        def self.write(common_dir, sha)
          path = File.join(common_dir, FILE)
          File.write(path, JSON.generate("sha" => sha, "verdict" => "green", "at" => Time.now.utc.iso8601))
          path
        end

        # @param common_dir [String] the repository's common git directory
        # @return [Hash, nil] `sha`, `verdict` and `at`, or nil when no finish has recorded one
        def self.read(common_dir)
          path = File.join(common_dir, FILE)
          JSON.parse(File.read(path)) if File.exist?(path)
        rescue JSON::ParserError
          nil
        end

        # What a finish does after the landing: records the gate verdict and says so in the report.
        module Gating
          private

          # The git directory is read first: the landing may remove the worktree we stand in.
          def gated(onto)
            common = common_git_dir
            landed = yield
            GateMarker.write(common, landed.dig(:landed, :value)) if onto == "main"
            said = "#{landed[:report][:value]}; tests: quick gate green"
            landed.merge(report: { value: said })
          end
        end
      end
    end
  end
end
