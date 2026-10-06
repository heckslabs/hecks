# frozen_string_literal: true

module Hecks
  module Tools
    module Lanes
      # The rulesets GitHub holds for the guarded lanes, compared with the projection and, when
      # confirmed, made to match it: the one step of `project_lanes` that changes GitHub.
      class Live
        # @param github [Hecks::Adapters::GithubRulesets] reads and writes GitHub's rulesets
        def initialize(github)
          @github = github
        end

        # @param confirm [Boolean] whether to create or update the rulesets
        # @return [Integer] 0 when GitHub agrees (or was made to), else 1
        def run(confirm)
          found = Lanes.lanes.select { |lane| lane["guarded"] == "yes" }.flat_map { |lane| sync(lane, confirm) }
          puts "lanes: GitHub holds every guarded lane's ruleset as projected" if found.empty? && !confirm
          return 0 if found.empty?

          warn "lanes: GitHub differs from the model (add --confirm to make it match)"
          1
        end

        private

        # @return [Array<String>] the differences left after the lane was looked at
        def sync(lane, confirm)
          projected = Lanes.ruleset(lane)
          differences = @github.differences(projected, @github.named(projected["name"]))
          differences.each { |line| puts line }
          return [] if differences.empty?
          return differences unless confirm

          puts "#{projected["name"]}: #{@github.apply(projected)}"
          []
        end
      end
    end
  end
end
