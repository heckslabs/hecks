# frozen_string_literal: true

module Hecks
  module Tools
    module AgentRoles
      # Reads the `RoleFile` rows from the Agents bluebook, each with its role's `RoleServer` rows.
      module Rows
        module_function

        # @param root [String] the checkout
        # @return [Array<Hash>] one row per role, in the bluebook's order, each with its `servers`
        #   (the `RoleServer` rows of that role, none for most)
        def read(root)
          servers = table(root, "RoleServer").group_by { |row| row[:role] }
          table(root, "RoleFile").map { |row| row.merge(servers: servers.fetch(row[:role], [])) }
        end

        # @param root [String] the checkout
        # @return [Array<String>] each role that has `RoutingRule` rows, first seen first
        def guarded(root) = table(root, "RoutingRule").map { |row| row[:role] }.uniq

        # @param root [String] the checkout
        # @return [Hash{String => Array<String>}] each role's `RoutingRule` patterns, in row order
        def commands(root)
          table(root, "RoutingRule").group_by { |row| row[:role] }.transform_values { |rows| rows.map { |row| row[:pattern] } }
        end

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
