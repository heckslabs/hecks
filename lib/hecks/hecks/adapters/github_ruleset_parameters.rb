# frozen_string_literal: true

module Hecks
  module Adapters
    # The parameters of a ruleset's rules, compared with GitHub's and carried across an update.
    #
    # A lane projects only some of a rule's parameters. A parameter the projection holds is
    # compared; one only GitHub holds (a required reviewer, a dismissal restriction) is not a
    # difference, and an update keeps it instead of dropping it.
    module GithubRulesetParameters
      # Rules whose parameters are compared elsewhere (by required check).
      SKIPPED = %w[required_status_checks].freeze

      module_function

      # @param projected [Hash] the ruleset as `Tools::Lanes` projects it
      # @param live [Hash] the ruleset GitHub holds
      # @return [Array<String>] one line for each projected parameter that GitHub holds differently
      def differences(projected, live)
        Array(projected["rules"]).flat_map do |rule|
          next [] if SKIPPED.include?(rule["type"])

          rule_differences(projected["name"], rule, find(live, rule["type"]))
        end
      end

      # @param projected [Hash] the ruleset as `Tools::Lanes` projects it
      # @param live [Hash, nil] the ruleset GitHub holds, nil when it has none
      # @return [Hash] the projection with every parameter only GitHub holds added to its rule
      def preserve(projected, live)
        return projected unless live

        projected.merge("rules" => projected.fetch("rules").map { |rule| keep(rule, find(live, rule["type"])) })
      end

      # @return [Hash, nil] the rule of that type in a ruleset
      def find(ruleset, type) = Array(ruleset["rules"]).find { |rule| rule["type"] == type }

      # @return [Hash] the parameters of a rule, empty when it has none
      def parameters(rule) = (rule && rule["parameters"]) || {}

      # @return [Array<String>] the differences of one projected rule against GitHub's
      def rule_differences(name, rule, theirs)
        kept = parameters(theirs)
        parameters(rule).reject { |key, value| kept[key] == value }.map do |key, value|
          "#{name}: #{rule["type"]} #{key} is #{kept[key].inspect} on GitHub, #{value.inspect} in the model"
        end
      end

      # @return [Hash] the rule with the parameters only the live rule holds added
      def keep(rule, theirs)
        extra = parameters(theirs).reject { |key, _| parameters(rule).key?(key) }
        return rule if extra.empty?

        rule.merge("parameters" => parameters(rule).merge(extra))
      end
    end
  end
end
