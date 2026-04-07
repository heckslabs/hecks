# GoHecks::EventGenerator
#
# Generates a Go struct for a domain event. Events are immutable value
# types with an OccurredAt timestamp and an EventName() method.
#
#   EventGenerator.new(event, aggregate: agg, package: "domain").generate
#
module GoHecks
  class EventGenerator
    include GoUtils

    def initialize(event, aggregate:, package:, name_suffix: "")
      @event = event
      @aggregate = aggregate
      @package = package
      @go_name = event.name + name_suffix
    end

    def generate
      b = GoCodeBuilder.new(@package)
      b.imports('"time"')

      b.struct(@go_name) do |s|
        s.field("AggregateID", "string", json: "aggregate_id")
        each_event_attr { |f, t, j| s.field(f, t, json: j) }
        each_extra_agg_attr { |f, t, j| s.field(f, t, json: j) }
        s.field("OccurredAt", "time.Time", json: "occurred_at")
      end

      b.one_liner(@go_name, "EventName", "string", "return \"#{@event.name}\"", pointer: false)
      b.blank
      b.one_liner(@go_name, "GetOccurredAt", "time.Time", "return e.OccurredAt", pointer: false)

      b.to_s
    end

    private

    def each_event_attr
      @event.attributes.each do |attr|
        yield GoUtils.pascal_case(attr.name), GoUtils.go_type(attr), GoUtils.json_tag(attr.name)
      end
    end

    def each_extra_agg_attr
      agg_attrs = @aggregate.attributes.reject { |a| Hecks::Utils::RESERVED_AGGREGATE_ATTRS.include?(a.name.to_s) }
      agg_attrs.each do |attr|
        next if @event.attributes.any? { |ea| ea.name == attr.name }
        yield GoUtils.pascal_case(attr.name), GoUtils.go_type(attr), GoUtils.json_tag(attr.name)
      end
    end
  end
end
