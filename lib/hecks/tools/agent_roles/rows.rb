# frozen_string_literal: true

module Hecks
  module Tools
    module AgentRoles
      # Reads the `RoleFile` rows from the Agents bluebook.
      module Rows
        # Roles whose file holds frontmatter a row cannot say yet (architect's `mcpServers` block).
        LEFT_OUT = %w[architect].freeze

        module_function

        # @param root [String] the checkout
        # @return [Array<Hash>] one row per projected role, in the order the bluebook lists them
        def read(root)
          role = agents(root).aggregates.find { |aggregate| aggregate.hecks_name == "Role" }
          members = role.value_objects.find { |object| object.hecks_name == "RoleFile" }.members
          members.reject { |row| LEFT_OUT.include?(row[:role]) }
        end

        # @return [Object] the Agents bluebook of the checkout
        def agents(root) = registry(root).bluebooks.fetch("Agents")

        # @return [Object] the registry the bluebook folder describes
        def registry(root) = Hecks.describe(File.join(root, BLUEBOOK)).registry
      end
    end
  end
end
