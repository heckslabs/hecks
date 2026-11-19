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
        def read(root) = table(root, "RoleFile").reject { |row| LEFT_OUT.include?(row[:role]) }

        # @param root [String] the checkout
        # @return [Array<String>] each role that has `RoutingRule` rows, first seen first
        def guarded(root) = table(root, "RoutingRule").map { |row| row[:role] }.uniq

        # @param root [String] the checkout
        # @param name [String] a value object of the `Role` aggregate
        # @return [Array<Hash>] its rows
        def table(root, name)
          role = agents(root).aggregates.find { |aggregate| aggregate.hecks_name == "Role" }
          role.value_objects.find { |object| object.hecks_name == name }.members
        end

        # @return [Object] the Agents bluebook of the checkout
        def agents(root) = registry(root).bluebooks.fetch("Agents")

        # @return [Object] the registry the bluebook folder describes
        def registry(root) = Hecks.describe(File.join(root, BLUEBOOK)).registry
      end
    end
  end
end
