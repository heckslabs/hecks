# frozen_string_literal: true

module Hecks
  module Tools
    module AgentRoles
      # Reads the `RoleFile` rows from the Agents bluebook.
      module Rows
        module_function

        # @param root [String] the checkout
        # @return [Array<Hash>] one row per role, in the order the bluebook lists them
        def read(root)
          role = agents(root).aggregates.find { |aggregate| aggregate.hecks_name == "Role" }
          role.value_objects.find { |object| object.hecks_name == "RoleFile" }.members
        end

        # @return [Object] the Agents bluebook of the checkout
        def agents(root) = registry(root).bluebooks.fetch("Agents")

        # @return [Object] the registry the bluebook folder describes
        def registry(root) = Hecks.describe(File.join(root, BLUEBOOK)).registry
      end
    end
  end
end
