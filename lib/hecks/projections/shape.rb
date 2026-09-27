require_relative "../ports/persistence"
require_relative "../projector"

module Hecks
  module Projections
    # The storage shape of one bluebook, the form `StorageShape.mint_hash` hashes to name an era.
    # Diffing two of these answers whether a change bumps the era.
    module Shape
      extend Projector::Target

      projects_as :shape

      module_function

      # Registered even when the era plugin is unloaded; the call then refuses clearly.
      def call(bluebook:, options: {})
        unless Ports::Persistence.plugin?(:era)
          raise "the :shape projection needs the era persistence plugin loaded " \
                "(require \"hecks/ports/persistence/plugins/era\")"
        end

        Runtime::StorageShape.project(bluebook)
      end
    end
  end
end
