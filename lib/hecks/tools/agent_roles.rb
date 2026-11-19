# frozen_string_literal: true

require "hecks"
require_relative "../tools"

module Hecks
  module Tools
    # Projects the `RoleFile` rows of the Agents bluebook's `Role` aggregate into the role files
    # of a checkout, `.claude/agents/<role>.md`: the frontmatter Claude Code reads (name,
    # description, tools, model) with a generated-file banner inside it, then the purpose, steps,
    # rules and handback of the role.
    #
    # Without a flag the files are written, except that a file whose frontmatter holds a key the row
    # cannot say (an `mcpServers` block) is refused by name and left alone. `--check` writes nothing
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

      module_function

      # @param argv [Array<String>] `--check` to compare without writing
      # @param root [String] the checkout
      # @param rows [Array<Hash>, nil] the `RoleFile` rows; a spec replaces them
      # @param out [String, nil] the directory the files live in; a spec replaces it
      # @param guarded [Hash, nil] `path:` and `roles:` of the guarded-role list; a spec replaces it
      # @return [Integer] 0, or 1 when `--check` finds a file out of date or a write is refused
      def main(argv, root: Tools::ROOT, rows: nil, out: nil, guarded: nil)
        parts(root, rows, out, guarded).map { |part| argv.include?("--check") ? part.check : part.write }.max
      end

      # The role files, and the guarded-role list unless a spec replaced only the role files.
      #
      # @return [Array<Files, Guarded>] what the run writes or compares
      def parts(root, rows, out, guarded)
        files = Files.new(out || File.join(root, AGENTS), rows || Rows.read(root))
        return [files] if out && guarded.nil?

        list = guarded || { path: File.join(root, GUARDED), roles: Rows.guarded(root) }
        [files, Guarded.new(list.fetch(:path), list.fetch(:roles))]
      end
    end
  end
end

require_relative "agent_roles/rows"
require_relative "agent_roles/render"
require_relative "agent_roles/files"
require_relative "agent_roles/guarded"
