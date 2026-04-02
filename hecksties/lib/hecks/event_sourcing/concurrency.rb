# Hecks::EventSourcing::Concurrency
#
# Optimistic concurrency control for event-sourced aggregates. Mixes a
# `_version` field onto aggregate instances and enforces version checks
# before persisting. Raises ConcurrencyError when the stored version has
# moved past the expected version, preventing lost-update anomalies.
#
# == Usage
#
#   Concurrency.stamp!(aggregate, 3)
#   aggregate._version  # => 3
#
#   Concurrency.check!(expected: 2, actual: 3)
#   # => raises Hecks::ConcurrencyError
#
module Hecks
  module EventSourcing
    module Concurrency
      # Stamps a version number onto an aggregate instance.
      #
      # @param aggregate [Object] the aggregate to stamp
      # @param version [Integer] the version to assign
      # @return [Integer] the assigned version
      def self.stamp!(aggregate, version)
        aggregate.instance_variable_set(:@_version, version)
        unless aggregate.respond_to?(:_version)
          aggregate.define_singleton_method(:_version) { @_version }
        end
        version
      end

      # Reads the current version from an aggregate, defaulting to 0.
      #
      # @param aggregate [Object] the aggregate to read
      # @return [Integer] the current version
      def self.version_of(aggregate)
        aggregate.respond_to?(:_version) ? (aggregate._version || 0) : 0
      end

      # Raises ConcurrencyError when expected and actual versions diverge.
      #
      # @param expected [Integer] the version the caller believes is current
      # @param actual [Integer] the version currently stored
      # @raise [Hecks::ConcurrencyError] if versions do not match
      def self.check!(expected:, actual:)
        return if expected == actual
        raise Hecks::ConcurrencyError,
          "Expected version #{expected} but store has #{actual}"
      end
    end
  end
end
