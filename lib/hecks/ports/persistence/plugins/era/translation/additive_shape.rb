require_relative "../storage_shape"
require_relative "../projected_bluebook"

module Hecks
  module Translation
    # The one rule for whether a change to an aggregate's storage shape only adds: its identity and
    # lifecycle field are as they were, every attribute it held is held exactly as before (same
    # name, same list or scalar form, same type with the same members), and each attribute it gained
    # is optional. Anything else is breaking, and a caller that cannot tell treats it as breaking.
    #
    # The implicit edge and the disposable ledger both ask it, so the two never disagree.
    #
    # **Known limits.** A stored projection leaves out `optional` and a lifecycle's states, so an
    # attribute that became required, or a state that was removed, is seen only when the held side
    # is a full declaration; between two projections it cannot be told from an unchanged shape.
    module AdditiveShape
      # The parts of a projected aggregate besides its attributes that its stored rows depend on.
      KEYS = %w[identity lifecycle_field].freeze

      module_function

      # @param held [Hash] the held aggregate's projection, as `StorageShape.project` builds it
      # @param current [Hash] the booting aggregate's projection
      # @param optional [#call] answers, given a name, whether the booting aggregate declares
      #   that attribute optional
      # @param was_optional [#call, nil] answers whether the held aggregate declared an attribute
      #   optional, or nil when the held side is a projection that does not say
      # @return [Boolean] whether `current` only adds to `held`
      def widened?(held, current, optional:, was_optional: nil)
        return false unless held.values_at(*KEYS) == current.values_at(*KEYS)
        return false unless (held["attributes"] - current["attributes"]).empty?
        return false if tightened?(held, optional, was_optional)

        (names(current) - names(held)).all? { |name| optional.call(name) }
      end

      # Whether an attribute the held declaration marked optional is required now.
      #
      # @return [Boolean]
      def tightened?(held, optional, was_optional)
        return false unless was_optional

        names(held).any? { |name| was_optional.call(name) && !optional.call(name) }
      end

      # @return [Array<String>] the attribute names of a projected aggregate
      def names(projected) = projected["attributes"].map { |attribute| attribute["name"] }

      # Whether every aggregate present in both shapes only adds. A shared aggregate that is
      # unchanged counts; one the current side lacks or the held side lacks is not this check's
      # business (the scaffold diff names renames, retirements and new aggregates).
      #
      # @param held [Hash, Runtime::ProjectedBluebook, Bluebook::Declaration] the held side
      # @param current [Bluebook::Declaration] the booting bluebook
      # @return [Boolean]
      def additive?(held, current)
        held_by = by_name(shape_of(held))
        by_name(Runtime::StorageShape.project(current)).all? do |name, projected|
          held_by[name].nil? || aggregate_additive?(held, held_by[name], projected, current.aggregate(name))
        end
      end

      # @return [Boolean] whether one aggregate present in both shapes only adds
      def aggregate_additive?(held, before, after, aggregate)
        states_kept?(held, aggregate) &&
          widened?(before, after, optional: optional_in(aggregate), was_optional: was_optional_in(held, aggregate.name))
      end

      # Whether every lifecycle state the held declaration had is still declared. A held side that
      # is a projection records no states, so it answers true.
      #
      # @return [Boolean]
      def states_kept?(held, aggregate)
        return true if held.is_a?(Hash) || held.is_a?(Runtime::ProjectedBluebook)

        before = states_of(held.aggregate(aggregate.name))
        before.nil? || ((before - Array(states_of(aggregate))).empty? && !states_of(aggregate).nil?)
      end

      # @return [Array<String>, nil] the lifecycle states an aggregate declares; nil without one
      def states_of(aggregate)
        lifecycle = aggregate&.lifecycle
        lifecycle&.states
      end

      # @return [Hash] the storage shape of any held side
      def shape_of(held)
        held = Runtime::ProjectedBluebook.wrap(held)
        held.is_a?(Runtime::ProjectedBluebook) ? held.projection : Runtime::StorageShape.project(held)
      end

      # @return [Hash{String => Hash}] each projected aggregate by name
      def by_name(shape) = shape["aggregates"].to_h { |aggregate| [aggregate["name"], aggregate] }

      # @return [#call] whether the aggregate declares the named attribute optional
      def optional_in(aggregate) = ->(name) { aggregate&.attribute(name)&.optional? || false }

      # @return [#call, nil] whether the held declaration's aggregate declared the named attribute
      #   optional; nil for a projection, which does not record it
      def was_optional_in(held, name)
        return nil if held.is_a?(Hash) || held.is_a?(Runtime::ProjectedBluebook)

        optional_in(held.aggregate(name))
      end
    end
  end
end
