# = Hecks::Conventions::EventContract
#
# Formalizes the event interface and cross-domain source tagging
# convention. Used by event generators (Go, Ruby) to validate that
# generated event structs match the domain IR, and by FilteredEventBus
# for source tagging.
#
#   Hecks::Conventions::EventContract::SOURCE_ATTR       # => :@_source_domain
#   Hecks::Conventions::EventContract.validate(event_ir, [:name, :description])
#   # => { missing: [], extra: [], valid: true }
#
module Hecks::Conventions
  # Hecks::Conventions::EventContract
  #
  # Event interface, required fields, and validation for cross-target event parity.
  #
  module EventContract
    # Every generated event must respond to these methods.
    INTERFACE = %i[event_name occurred_at].freeze

    # Instance variable used by FilteredEventBus to tag event source domain.
    SOURCE_ATTR = :@_source_domain

    # Standard fields present on every generated event, beyond the
    # domain-specific attributes. Generators for all targets must
    # include these fields.
    REQUIRED_FIELDS = {
      aggregate_id: { ruby: "String", go: "string", json: "aggregate_id" },
      occurred_at:  { ruby: "Time",   go: "time.Time", json: "occurred_at" },
    }.freeze

    # Validate that generated event fields match the domain IR definition.
    #
    # @param event_ir [DomainModel::Behavior::Event] the event from the IR
    # @param generated_attrs [Array<String, Symbol>] field names in generated code
    # @return [Hash] { missing:, extra:, valid: }
    def self.validate(event_ir, generated_attrs)
      expected = event_ir.attributes.map { |a| a.name.to_s }
      actual = generated_attrs.map(&:to_s) - ["occurred_at"]
      missing = expected - actual
      extra = actual - expected
      { missing: missing, extra: extra, valid: missing.empty? && extra.empty? }
    end
  end
end
