require_relative "../../../../ports/persistence/plugins/era/storage_shape"
require_relative "../../../../runtime/errors"

module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # What a held era holds: its storage shape, and the declaration its held text parses to.
        #
        # The shape is the projection the era's mint recorded, read as stored. The held text is the
        # domain's source as the mint read it; an era minted before the source covered a domain's
        # module folders holds the top-level file alone, which declares none of the folders'
        # aggregates. Its declaration is answered only when it parses to the recorded shape.
        # LineageManager extends it, so each method is called on LineageManager.
        module HeldEra
          # @param era [Hash] an era as `Lineage#eras` answers it: `held_text`, and `projection`
          #   when its mint recorded one
          # @return [Hash] the storage shape the era holds, as `StorageShape.project` answers it
          def held_shape(era) = era[:projection] || Runtime::StorageShape.project(shadow(era[:held_text]))

          # Whether the era's held text parses to the shape its mint recorded, so a field-by-field
          # diff from it is a diff from the era. An era with no recorded projection is taken at its
          # text.
          #
          # @param era [Hash] an era as `Lineage#eras` answers it
          # @return [Boolean]
          def whole_held_text?(era)
            era[:projection].nil? || Runtime::StorageShape.project(shadow(era[:held_text])) == era[:projection]
          end

          # The declaration an era holds, for a caller that diffs it field by field.
          #
          # @param era [Hash] an era as `Lineage#eras` answers it
          # @return [Bluebook::Declaration] the declaration the held text parses to
          # @raise [Runtime::WiringError] naming the era, when its held text does not parse to the
          #   shape its mint recorded
          def held_declaration(era)
            raise Runtime::WiringError, partial_text_refusal(era) unless whole_held_text?(era)

            shadow(era[:held_text])
          end

          # @param era [Hash] the era whose text is partial
          # @return [String] the refusal naming the era and what to do instead
          def partial_text_refusal(era)
            "era #{era[:ordinal]} (#{era[:label]}) holds part of its domain's source: its held text " \
              "does not declare the shape its mint recorded, so nothing can be diffed from it field " \
              "by field. Write the translation edge from #{era[:label]} by hand; the next era minted " \
              "holds the whole domain."
          end
        end
      end
    end
  end
end
