# frozen_string_literal: true

require "hecks"
require_relative "shell_reads"

module Hecks
  module Adapters
    # The `Routing` port's adapter: answers `Guard` for a role and one command from the
    # `RoutingRule` and `RefusalHint` rows of the Agents bluebook's Role aggregate. It holds no
    # list of its own; a change to what a role may run is a change to `agents.bluebook`. A refusal
    # is raised, so the launcher exits non-zero and prints the reason.
    class RoutingGuard
      # A command the role may not run itself, with the verb or role to use instead.
      class Refused < StandardError; end

      BLUEBOOK_DIR = File.expand_path("..", __dir__)
      LAUNCHER = %r{\A(?:\./)?(?:exe/)?hecks\s+}
      CHAINING = /[;&|<>`\n]|\$\(/
      # An `Aggregate.verb` word of a launcher call, in either spelling.
      VERB_WORD = /\A[A-Za-z_]\w*\.\w/

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `rows:` a callable answering a value object's name => its rows
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @rows = settings[:rows] || method(:bluebook_rows)
      end

      # @param role [Hash, String] the role asking
      # @param command [Hash, String] the Bash text it asks to run
      # @return [Hash{Symbol => String}] `text:` "allowed"
      # @raise [Refused] when the role has routing rows and the command is not on them
      def guard(role:, command:)
        name = held(role)
        rules = rows("RoutingRule", name).map { |row| row[:pattern] }
        text = held(command).to_s.strip
        return { text: "allowed" } if rules.empty? || allowed?(rules, text, name)

        raise Refused, refusal(name, text)
      end

      private

      def allowed?(rules, text, name = nil)
        return false if text.match?(CHAINING)
        return ShellReads.new(rules, rows("ShellFlagRule", name)).allowed?(text) if ShellReads.shell?(text)
        return false unless text.match?(LAUNCHER)

        verb = verb_of(text.sub(LAUNCHER, ""))
        rules.any? { |rule| rule.end_with?(".*") ? verb.start_with?(rule.delete_suffix("*")) : verb == rule }
      end

      # The `Aggregate.verb` a launcher call names, past an optional domain word.
      def verb_of(call)
        words = call.split
        words.find { |word| word.match?(VERB_WORD) } || words.first.to_s
      end

      def refusal(name, text)
        use = rows("RefusalHint", name).find { |row| text.start_with?(row[:shape]) }&.fetch(:use)
        use ||= "a verb on the #{name} routing list, or dispatch another role through Work.plan!/Dispatch"
        "#{name} routes only: use #{use}. Refused: #{text}"
      end

      def rows(table, role) = @rows.call(table).select { |row| row[:role] == role }

      def held(value) = value.is_a?(Hash) ? value.fetch(:value) { value.fetch("value", nil) } : value

      def bluebook_rows(table)
        aggregate = bluebook.aggregates.find { |candidate| candidate.hecks_name == "Role" }
        aggregate.value_objects.find { |object| object.hecks_name == table }.members
      end

      def bluebook = (@bluebook ||= described.bluebooks.fetch("Agents"))

      def described = Hecks.describe(BLUEBOOK_DIR).registry
    end
  end
end
