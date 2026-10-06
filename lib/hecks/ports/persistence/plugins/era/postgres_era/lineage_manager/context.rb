module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # Everything one era check carries from connecting to minting: the booting registry and
        # bluebook, its source text, the open lineage, the role to grant, the bluebook directory,
        # and the latest held era once the held eras were read.
        Context = Data.define(:registry, :bluebook, :current_text, :lineage, :role, :directory, :latest) do
          def initialize(latest: nil, **rest) = super

          # @return [Integer] the ordinal of the era a mint would create
          def ordinal = latest[:ordinal] + 1

          # @return [String] the storage-shape hash of the current bluebook
          def shape_hash = Runtime::StorageShape.mint_hash(bluebook)

          # @return [String] the short label naming the current shape
          def label = shape_hash[0, Runtime::StorageShape::LABEL_LENGTH]

          # @return [Hash] the storage shape of the current bluebook
          def current_shape = Runtime::StorageShape.project(bluebook)

          # Records the era this boot resolved to on the registry.
          #
          # @param ordinal [Integer] the resolved era
          # @return [Integer] `ordinal`
          def record_resolved(ordinal) = registry.resolved_eras[bluebook.name] = ordinal

          # Records the era that superseded the one this boot resolved to.
          #
          # @param ordinal [Integer] the superseding era
          # @return [Integer] `ordinal`
          def record_superseded(ordinal) = registry.superseded_eras[bluebook.name] = ordinal
        end
      end
    end
  end
end
