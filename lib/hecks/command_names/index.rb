require "hecks/adapters/driving/cli_runner"
require_relative "resolution"

module Hecks
  module CommandNames
    # The launcher's accepted names, by scope, and what becomes of a typed line.
    class Index
      # Words the launcher answers before it looks a name up.
      PROGRAM_WORDS = %w[help usage search tour completion resume].freeze

      # @param scopes [Hash{String => Hash}] `CliRunner.name_index`
      def initialize(scopes)
        @scopes = scopes
      end

      # @param words [Array<String>] the words after the launcher's name
      # @return [Problem, nil] what is wrong with the line, or nil when the launcher accepts it
      def problem(words)
        scope, rest = scope_of(words)
        asking = Adapters::Driving::CliRunner::QUERY_WORDS.include?(rest.first)
        typed = rest.drop(asking ? 1 : 0).first
        return if typed.nil? || free?(scope, typed)

        Resolution.new(scope, typed, asking).problem
      end

      private

      # An attached bluebook's word hands the rest of the line to that bluebook.
      def scope_of(words)
        scope = words.first && !words.first.empty? && @scopes[words.first]
        scope ? [scope, words.drop(1)] : [@scopes.fetch(""), words]
      end

      def free?(scope, typed)
        PROGRAM_WORDS.include?(typed) || scope["modules"].include?(typed)
      end
    end
  end
end
