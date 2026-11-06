require_relative "../../../../ports/persistence/plugins/era/storage_shape"
require_relative "../../../../ports/persistence/plugins/era/projected_bluebook"
require_relative "../../../../runtime/errors"

module Hecks
  module Adapters
    class PostgresRevision
      module LineageManager
        # What a held era is: the storage shape its mint recorded, and the hash of that shape.
        #
        # Held text is kept for audit and decides nothing. An era minted without a stored shape is
        # read from its held text only when that text is the whole domain, which it is when it
        # hashes to the era's stored hash; otherwise the era is refused by name. LineageManager
        # extends it, so each method is called on LineageManager.
        module HeldRevision
          # @param era [Hash] an era as `Lineage#eras` answers it: `projection` when its mint
          #   recorded one, `hash` once it is named, and `held_text`
          # @return [Hash] the storage shape the era holds
          # @raise [Runtime::WiringError] naming the era, when it stores no shape and its held text
          #   does not hash to its stored hash
          def held_shape(era) = era[:projection] || verified_text_shape(era) || refuse_unshaped!(era)

          # The held era as a bluebook view over its storage shape, for a diff, the additive rule or
          # the coverage check.
          #
          # @param era [Hash] an era as `Lineage#eras` answers it
          # @return [Runtime::ProjectedBluebook]
          # @raise [Runtime::WiringError] as `held_shape`
          def held_bluebook(era) = Runtime::ProjectedBluebook.new(held_shape(era))

          # The era's hash: the one it stores once named, else the hash of the shape it holds.
          #
          # @param era [Hash] an era as `Lineage#eras` answers it
          # @return [String] 64 lowercase hex characters
          def held_hash(era) = era[:hash] || held_bluebook(era).mint_hash

          # The shape an era's held text declares, when the text hashes to the era's stored hash and
          # so is the whole domain the era was minted from; nil otherwise.
          #
          # @param era [Hash] an era with no stored shape
          # @return [Hash, nil]
          def verified_text_shape(era)
            return unless era[:hash] && era[:held_text]

            declared = shadow(era[:held_text])
            Runtime::StorageShape.project(declared) if declared && Runtime::StorageShape.mint_hash(declared) == era[:hash]
          rescue StandardError, SyntaxError
            nil
          end

          # @raise [Runtime::WiringError] always, naming the era and why its shape is unknown
          def refuse_unshaped!(era)
            raise Runtime::WiringError,
                  "era #{era[:ordinal]} (#{era[:label] || "unnamed"}) stores no storage shape, and its held " \
                  "text #{unverified_reason(era)}, so it is not the whole domain the era was minted from"
          end

          # @return [String] why an era's held text cannot stand in for its missing shape
          def unverified_reason(era)
            return "has no stored hash to check it against" unless era[:hash]

            "does not hash to its stored hash"
          end
        end
      end
    end
  end
end
