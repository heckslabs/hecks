# frozen_string_literal: true

require "hecks"
require_relative "../tools"

module Hecks
  module Tools
    # Projects the `RoleFile` rows of the Agents bluebook's `Role` aggregate into the role files of a
    # checkout, `.claude/agents/<role>.md`: the frontmatter Claude Code reads (name, description,
    # tools, model) with a generated-file banner inside it, then the purpose, steps, rules and
    # handback of the role.
    #
    # Without a flag the files are written, except that a file whose frontmatter holds a key the row
    # cannot say (an `mcpServers` block) is refused by name and left alone. `--check` writes nothing
    # and answers 1, naming each file that is missing or differs from its row.
    module AgentRoles
      # Where the role files live, relative to the checkout.
      AGENTS = ".claude/agents"

      # The bluebook folder that declares the `Role` rows, relative to the checkout.
      BLUEBOOK = "lib/hecks/agents"

      module_function

      # @param argv [Array<String>] `--check` to compare without writing
      # @param root [String] the checkout
      # @param rows [Array<Hash>, nil] the `RoleFile` rows; a spec replaces them
      # @param out [String, nil] the directory the files live in; a spec replaces it
      # @return [Integer] 0, or 1 when `--check` finds a file out of date or a write is refused
      def main(argv, root: Tools::ROOT, rows: nil, out: nil)
        files = Files.new(out || File.join(root, AGENTS), rows || Rows.read(root))
        argv.include?("--check") ? files.check : files.write
      end
    end
  end
end

require_relative "agent_roles/rows"
require_relative "agent_roles/render"
require_relative "agent_roles/files"
