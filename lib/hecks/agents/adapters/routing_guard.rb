# frozen_string_literal: true

require "hecks"
require_relative "shell_reads"
require_relative "role_server_env"

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
      # @param agent [Hash, String, nil] the subagent making the call; blank in the role's session
      # @return [Hash{Symbol => String}] `text:` "allowed"
      # @raise [Refused] when the role's own session has routing rows and the command is not on them
      def guard(role:, command:, agent: nil)
        return { text: "allowed" } unless held(agent).to_s.strip.empty?

        name = held(role)
        rules = rows("RoutingRule", name).map { |row| row[:pattern] }
        text = held(command).to_s.strip
        return { text: "allowed" } if rules.empty? || allowed?(rules, text, name)

        raise Refused, refusal(name, text)
      end

      # The variables that start the role's MCP server restricted to the commands its rows name.
      #
      # @param role [Hash, String] the role asking
      # @return [Hash{Symbol => String}] `text:` one `NAME=value` line each, empty when the role has
      #   no rows that name a command of the served domain and so stays unrestricted
      def server_env(role:)
        { text: server_variables(held(role)).map { |name, value| "#{name}=#{value}" }.join("\n") }
      end

      # @param name [String] the role
      # @return [Hash{String => String}] the `HECKS_SERVER_*` variables, or empty
      def server_variables(name)
        patterns = rows("RoutingRule", name).map { |row| row[:pattern] }
        return {} if patterns.empty?

        RoleServerEnv.new(patterns: patterns, names: method(:command_names)).variables
      end

      private

      # The command names the Hecks domain has, as a person types them; read once per guard.
      def command_names
        @command_names ||= Driving::CliRunner.known_command_names(runtime: Hecks.describe(served_domain), program: "mcp")
      end

      def served_domain = File.expand_path("../hecks", BLUEBOOK_DIR)

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
        use = nearest_verb(name, text) || hint(name, text)
        "#{name} routes only: use #{use}. Refused: #{text}"
      end

      def hint(name, text)
        found = rows("RefusalHint", name).find { |row| text.start_with?(row[:shape]) }
        found ? found[:use] : "a verb on the #{name} routing list, or dispatch another role through Work.plan!"
      end

      # A routing row of the same aggregate as the launcher call, to name beside the refusal.
      def nearest_verb(name, text)
        return unless text.match?(LAUNCHER)

        aggregate = verb_of(text.sub(LAUNCHER, "")).split(".").first
        rows("RoutingRule", name).map { |row| row[:pattern] }.find { |rule| rule.start_with?("#{aggregate}.") }
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
