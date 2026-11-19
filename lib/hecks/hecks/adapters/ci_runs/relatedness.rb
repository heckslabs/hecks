# frozen_string_literal: true

require "json"
require_relative "../git_rehearsal/spec_map"

module Hecks
  module Adapters
    class CiRuns
      # Whether a train pull request's failing specs touch the files it changed, measured with the
      # push rehearsal's own map from changed files to the specs that exercise them. It answers
      # `yes`, `no`, or `unknown` when GitHub does not name the changed files or no spec failed by
      # name; what an unknown answer means is the bluebook's to say.
      class Relatedness
        # The most specs the map is asked for: enough that none of a change's specs is cut off.
        LIMIT = 100_000

        # @param runner [#call] takes `(argv, chdir:)` and answers `[ok, output]`
        # @param checkout [String] the directory `gh` runs in, whose `spec/` the map reads
        def initialize(runner, checkout)
          @runner = runner
          @checkout = checkout
        end

        # @param number [String] the pull request's number
        # @param specs [Array<String>] the failing spec files
        # @return [String] `yes`, `no` or `unknown`
        def judge(number, specs)
          changed = changed_files(number)
          return "unknown" if changed.nil? || changed.empty? || specs.empty?

          touched?(changed, specs) ? "yes" : "no"
        end

        private

        def touched?(changed, specs)
          return true if specs.intersect?(changed)

          mapped = GitRehearsal::SpecMap.new(@checkout).map(changed, limit: LIMIT).specs
          specs.intersect?(mapped)
        end

        # The paths the pull request changes, read over REST; nil when they cannot be read.
        def changed_files(number)
          argv = ["gh", "api", "--paginate", "--slurp", "repos/{owner}/{repo}/pulls/#{number}/files?per_page=100"]
          ok, output = @runner.call(argv, chdir: @checkout)
          return nil unless ok

          JSON.parse(output.to_s).flatten.map { |file| file["filename"].to_s }
        rescue JSON::ParserError, NoMethodError, TypeError
          nil
        end
      end
    end
  end
end
