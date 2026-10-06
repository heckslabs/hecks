# frozen_string_literal: true

require "json"
require "open3"

module Hecks
  module Adapters
    # The rulesets of the repository `gh` is pointed at, read and written through `gh api`.
    #
    # `Tools::Lanes` projects each guarded `Lane` row into a ruleset and uses this to compare the
    # projection with what GitHub holds, and to create or update it. Nothing here decides what a
    # ruleset says; it only carries a ruleset to and from GitHub. `{owner}/{repo}` is a `gh api`
    # template resolved from the git remote.
    class GithubRulesets
      # The part of a ruleset a lane projects: everything else GitHub fills in (ids, links,
      # timestamps, defaults) is left out of a comparison.
      COMPARED = %w[name target enforcement].freeze

      # @param runner [#call, nil] runs `gh` with its arguments and stdin text, answering
      #   `[stdout, stderr, success]`; the real `gh` when nil. A spec replaces it.
      def initialize(runner: nil)
        @runner = runner || method(:run_gh)
      end

      # @return [Array<Hash>] every ruleset of the repository, in full
      # @raise [RuntimeError] when `gh` is missing or refuses
      def all
        listed = json(call("api", "repos/{owner}/{repo}/rulesets?per_page=100"))
        listed.map { |ruleset| json(call("api", "repos/{owner}/{repo}/rulesets/#{ruleset.fetch('id')}")) }
      end

      # @param name [String] a ruleset's name
      # @return [Hash, nil] the ruleset of that name, or nil when the repository has none
      def named(name) = all.find { |ruleset| ruleset["name"] == name }

      # Makes the ruleset exist as projected: creates it, or updates the one of that name.
      #
      # @param projected [Hash] the ruleset as `Tools::Lanes` projects it
      # @return [Symbol] `:created` or `:updated`
      # @raise [RuntimeError] when GitHub refuses it
      def apply(projected)
        live = named(projected.fetch("name"))
        path = "repos/{owner}/{repo}/rulesets"
        if live
          call("api", "--method", "PUT", "#{path}/#{live.fetch('id')}", "--input", "-", stdin: JSON.generate(projected))
          :updated
        else
          call("api", "--method", "POST", path, "--input", "-", stdin: JSON.generate(projected))
          :created
        end
      end

      # How a live ruleset differs from a projected one, over the parts a lane projects.
      #
      # @param projected [Hash] the ruleset as `Tools::Lanes` projects it
      # @param live [Hash, nil] the ruleset GitHub holds, or nil when it has none
      # @return [Array<String>] one line for each difference; empty when they agree
      def differences(projected, live)
        return ["#{projected['name']}: GitHub has no such ruleset"] unless live

        found = COMPARED.reject { |key| projected[key] == live[key] }.map do |key|
          "#{projected['name']}: #{key} is #{live[key].inspect} on GitHub, #{projected[key].inspect} in the model"
        end
        found + compare_conditions(projected, live) + compare_bypass(projected, live) + compare_rules(projected, live)
      end

      private

      def compare_conditions(projected, live)
        mine = projected.dig("conditions", "ref_name", "include")
        theirs = live.dig("conditions", "ref_name", "include")
        mine == theirs ? [] : ["#{projected['name']}: it guards #{theirs.inspect} on GitHub, #{mine.inspect} in the model"]
      end

      def compare_bypass(projected, live)
        mine = actors(projected)
        theirs = actors(live)
        return [] if mine == theirs

        ["#{projected['name']}: bypass actors are #{theirs.inspect} on GitHub, #{mine.inspect} in the model"]
      end

      def compare_rules(projected, live)
        mine = projected.fetch("rules").map { |rule| rule["type"] }.sort
        theirs = live.fetch("rules", []).map { |rule| rule["type"] }.sort
        mine == theirs ? [] : ["#{projected['name']}: rules are #{theirs.inspect} on GitHub, #{mine.inspect} in the model"]
      end

      def actors(ruleset)
        Array(ruleset["bypass_actors"]).map { |actor| actor.values_at("actor_id", "actor_type", "bypass_mode") }.sort_by(&:to_s)
      end

      def call(*args, stdin: nil)
        out, err, ok = @runner.call(args, stdin)
        raise "gh #{args.first(3).join(' ')} failed: #{err.strip.empty? ? out.strip : err.strip}" unless ok

        out
      end

      def json(text) = JSON.parse(text)

      def run_gh(args, stdin)
        out, err, status = Open3.capture3("gh", *args, stdin_data: stdin.to_s)
        [out, err, status.success?]
      rescue Errno::ENOENT
        ["", "gh is not installed or not on PATH", false]
      end
    end
  end
end
