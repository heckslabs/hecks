# Hecks::EventSourcing::UpcasterEngine
#
# Applies a chain of upcasters to bring an event payload from its stored
# schema_version to the latest version. Walks the upcaster chain in order,
# applying each transform whose from_version matches the current version.
#
# == Usage
#
#   engine = UpcasterEngine.new(registry)
#   data = engine.upcast("CreatedPizza", { "name" => "M" }, from_version: 1)
#   # => { "name" => "M", "size" => "medium" }  (if v1->v2 adds size)
#
class Hecks::EventSourcing::UpcasterEngine
  # @param registry [Hecks::EventSourcing::UpcasterRegistry]
  def initialize(registry)
    @registry = registry
  end

  # Upcast event data from a given version through all registered transforms.
  #
  # @param event_type [String] the event class name
  # @param data [Hash] the event payload
  # @param from_version [Integer] the stored schema version
  # @return [Hash] the upcasted event payload at the latest version
  def upcast(event_type, data, from_version:)
    current_version = from_version
    result = data.dup

    @registry.upcasters_for(event_type).each do |upcaster|
      next if upcaster.from_version < current_version
      break if upcaster.from_version > current_version
      result = upcaster.transform.call(result)
      current_version = upcaster.to_version
    end

    result
  end
end
