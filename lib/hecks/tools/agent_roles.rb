# frozen_string_literal: true

require "hecks"
require_relative "../tools"

module Hecks
  module Tools
    # Projects the `RoleFile` rows of the Agents bluebook's `Role` aggregate into the role files
    # of a checkout, `.claude/agents/<role>.md`: the frontmatter Claude Code reads (name,
    # description, tools, model, and the `mcpServers` of its `RoleServer` rows) with a
    # generated-file banner inside it, then the purpose, steps, rules and handback of the role.
    #
    # Without a flag the files are written, except that a file whose frontmatter holds a key the row
    # cannot say (a `hooks` block, say) is refused by name and left alone. `--check` writes nothing
    # and answers 1, naming each file that is missing or differs from its row. The same run
    # projects the roles that have `RoutingRule` rows into `.claude/hooks/guarded_roles`, which
    # the Bash guard hook reads when `Role.guard` cannot answer.
    module AgentRoles
      # Where the role files live, relative to the checkout.
      AGENTS = ".claude/agents"

      # The bluebook folder that declares the `Role` rows, relative to the checkout.
      BLUEBOOK = "lib/hecks/agents"

      # The list of guarded roles the guard hook reads, relative to the checkout.
      GUARDED = ".claude/hooks/guarded_roles"

      # The rules file the guard hook decides from, relative to the checkout.
      RULES = ".claude/hooks/guard_rules.json"

      module_function

      # @param argv [Array<String>] `--check` to compare without writing
      # @param root [String] the checkout
      # @param rows [Array<Hash>, nil] the `RoleFile` rows; a spec replaces them
      # @param out [String, nil] the directory the files live in; a spec replaces it
      # @param lists [Hash] `guarded:` (`path:` and `roles:` of the guarded-role list) and `rules:`
      #   (`path:`, `agents:` and `commands:` of the guard rules file); a spec replaces them
      # @return [Integer] 0, or 1 when `--check` finds a file out of date or a write is refused
      def main(argv, root: Tools::ROOT, rows: nil, out: nil, **lists)
        check = argv.include?("--check")
        parts(root, rows, out, lists).map { |part| check ? part.check : part.write }.max
      end

      # The role files, then the guarded-role list and the guard rules file; a spec that replaced
      # the role files' directory gets only the lists it also replaced.
      #
      # @param lists [Hash] `guarded:` and `rules:`, each a spec's stand-in
      # @return [Array<Files, Guarded, GuardRules>] what the run writes or compares
      def parts(root, rows, out, lists)
        files = Files.new(out || File.join(root, AGENTS), rows || Rows.read(root))
        lists = defaults(root) if out.nil?
        [files, *lists[:guarded]&.then { |list| role_list(list) }, *lists[:rules]&.then { |list| rule_file(list) }]
      end

      # @return [Hash] the checkout's own guarded-role list and rules file
      def defaults(root)
        { guarded: { path: File.join(root, GUARDED), roles: Rows.guarded(root) },
          rules:   { path: File.join(root, RULES), agents: File.join(root, BLUEBOOK), commands: Rows.commands(root) } }
      end

      # @return [Guarded] the guarded-role list for `list`'s `path:` and `roles:`
      def role_list(list) = Guarded.new(list.fetch(:path), list.fetch(:roles))

      # @return [GuardRules] the rules file for `rules`' `path:`, `agents:` and `commands:`
      def rule_file(rules) = GuardRules.new(rules.fetch(:path), rules.fetch(:agents), rules.fetch(:commands))
    end
  end
end

require_relative "agent_roles/rows"
require_relative "agent_roles/render"
require_relative "agent_roles/files"
require_relative "agent_roles/guarded"
require_relative "agent_roles/guard_rules"
