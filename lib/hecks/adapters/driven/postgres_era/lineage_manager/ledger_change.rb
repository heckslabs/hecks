require_relative "../../../../ports/persistence/plugins/era/storage_shape"
require_relative "../../../../naming"

module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # The change between the storage shape a disposable ledger holds and the shape it boots
        # with, aggregate by aggregate. `added` names aggregates the held shape did not have,
        # `widened` those that only gained optional attributes, and `replaced` those whose stored
        # rows do not fit the booting shape: removed, or with an attribute renamed, dropped,
        # retyped or newly required, or a changed identity or lifecycle field. It reads and writes
        # nothing.
        LedgerChange = Data.define(:added, :widened, :replaced) do
          # @param held_projection [Hash] the held era's storage shape, as `StorageShape.project`
          #   answers it
          # @param bluebook [Bluebook::Declaration] the bluebook booting now
          # @return [LedgerChange]
          def self.between(held_projection, bluebook)
            held = by_name(held_projection)
            current = by_name(Runtime::StorageShape.project(bluebook))
            widened, broken = changed_in_both(held, current).partition do |name|
              widened?(held[name], current[name], bluebook.aggregate(name))
            end
            new(added: missing(held, current), widened: widened, replaced: broken + missing(current, held))
          end

          # @return [Hash{String => Hash}] each projected aggregate by its name
          def self.by_name(projection) = projection.fetch("aggregates", []).to_h { |aggregate| [aggregate["name"], aggregate] }

          # @return [Array<String>] the aggregates `to` has and `from` does not
          def self.missing(from, to) = to.keys - from.keys

          # @return [Array<String>] the aggregates both shapes have, whose shapes differ
          def self.changed_in_both(held, current) = (held.keys & current.keys).reject { |name| held[name] == current[name] }

          # Whether an aggregate kept its identity, lifecycle field and every attribute as it was
          # held, and gained only attributes it declares optional.
          #
          # @return [Boolean]
          def self.widened?(held, current, aggregate)
            return false unless held.values_at(*keys) == current.values_at(*keys)
            return false unless (held["attributes"] - current["attributes"]).empty?

            gained = names(current) - names(held)
            gained.all? { |name| aggregate.attribute(name)&.optional? }
          end

          # @return [Array<String>] the attribute names of a projected aggregate
          def self.names(projected) = projected["attributes"].map { |attribute| attribute["name"] }

          # @return [Array<String>] the parts of a projected aggregate besides its attributes that
          #   its stored rows depend on
          def self.keys = %w[identity lifecycle_field]
          private_class_method :by_name, :changed_in_both, :widened?, :names, :keys, :missing

          # @return [Boolean] whether the held shape and the booting shape differ at all
          def changed? = !(added.empty? && widened.empty? && replaced.empty?)

          # The storage name of a replaced aggregate: the booting bluebook's own, else the name the
          # held shape gave it, snake-cased the way an aggregate names its storage.
          #
          # @param bluebook [Bluebook::Declaration] the bluebook booting now
          # @param name [String] a name from `replaced`
          # @return [String]
          def storage_name(bluebook, name) = bluebook.aggregate(name)&.storage_name || Naming.snake(name)
        end
      end
    end
  end
end
