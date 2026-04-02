# Hecks::EventSourcing::UpcasterRegistry
#
# Registry for event upcasters. An upcaster transforms an event payload
# from one schema_version to the next. Multiple upcasters can be chained
# to migrate events through several versions.
#
# == Usage
#
#   registry = UpcasterRegistry.new
#   registry.register("CreatedPizza", from: 1, to: 2) do |data|
#     data.merge("size" => "medium")
#   end
#   registry.upcasters_for("CreatedPizza")
#   # => [#<Upcaster from=1 to=2>]
#
class Hecks::EventSourcing::UpcasterRegistry
  Upcaster = Struct.new(:event_type, :from_version, :to_version, :transform, keyword_init: true)

  def initialize
    @upcasters = Hash.new { |h, k| h[k] = [] }
  end

  # Register an upcaster for a specific event type and version transition.
  #
  # @param event_type [String] the event class name
  # @param from [Integer] the source schema version
  # @param to [Integer] the target schema version
  # @yield [data] transforms the event data hash
  # @yieldparam data [Hash] the event payload at the source version
  # @yieldreturn [Hash] the event payload at the target version
  # @return [void]
  def register(event_type, from:, to:, &transform)
    @upcasters[event_type.to_s] << Upcaster.new(
      event_type: event_type.to_s,
      from_version: from,
      to_version: to,
      transform: transform
    )
    @upcasters[event_type.to_s].sort_by!(&:from_version)
  end

  # Return all upcasters for a given event type, sorted by from_version.
  #
  # @param event_type [String] the event class name
  # @return [Array<Upcaster>] sorted upcasters
  def upcasters_for(event_type)
    @upcasters[event_type.to_s]
  end

  # Check if any upcasters are registered for the event type.
  #
  # @param event_type [String] the event class name
  # @return [Boolean]
  def any?(event_type)
    @upcasters[event_type.to_s].any?
  end
end
