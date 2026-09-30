# frozen_string_literal: true

module Hecks
  module Adapters
    # The `Make` port's adapter: reads the Makefiles a deploy recipe generates, as text, and reports
    # the recipes that touch AWS or a database and hide a failure.
    #
    # Nothing here runs `make`, `aws` or `psql`. With no Makefile named, it renders three
    # representative fixture domains in this process and lints what they generate.
    class Make
      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Lints Makefiles.
      #
      # @param held [Hash] the `RecipeLint` record: `makefiles` (comma separated paths)
      # @return [Hash{Symbol => Hash}] `report:` that no violation was found
      # @raise [RuntimeError] naming every violation, or the Makefile that cannot be read
      def check(**held)
        found = violations(plain(held[:makefiles]).to_s.split(",").map(&:strip).reject(&:empty?))
        raise (["#{found.size} violation(s) found:"] + found.map { |violation| "  #{violation}" }).join("\n") if found.any?

        { report: { value: "no violations found" } }
      rescue ArgumentError => e
        raise e.message
      end

      private

      def violations(paths)
        require_relative "../../projections/deploy/recipe_lint"
        lint = Projections::Deploy::RecipeLint
        paths.empty? ? lint.lint_fixtures : lint.lint_files(paths)
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
