  # Hecks::EventStormImporter
  #
  # Parses event storm documents (ASCII or YAML format) and produces a domain
  # object plus DSL source code. Supports both file paths and inline content
  # strings. Auto-detects YAML vs ASCII format based on file extension and
  # content patterns.
  #
  # Extended onto the top-level Hecks module to provide +Hecks.from_event_storm+.
  # The result includes the built domain, generated DSL code, and any parser
  # warnings (e.g., unrecognized lines or ambiguous aggregates).
  #
  #   Hecks.from_event_storm("event_storm.yml")
  #   Hecks.from_event_storm("event_storm.md", name: "Pizzas")
  #
module Hecks
  module EventStormImporter
    # Import an event storm document and produce a domain with DSL source.
    # Accepts either a file path or a raw content string. Detects YAML format
    # by file extension (.yml/.yaml) or by content patterns (domain:/contexts:/
    # aggregates: keys).
    #
    # @param source [String] file path to an event storm document, or raw
    #   event storm content as a string
    # @param name [String, nil] optional domain name override; if nil, the
    #   name is extracted from the event storm document itself
    # @return [EventStorm::Result] struct with :domain (Domain), :dsl (String),
    #   and :warnings (Array<String>)
    def from_event_storm(source, name: nil)
      content = File.exist?(source.to_s) ? File.read(source) : source
      yaml = source.to_s.match?(/\.ya?ml$/i) || content.match?(/\A\s*(?:domain|contexts|aggregates)\s*:/)
      result = (yaml ? EventStorm::YamlParser : EventStorm::Parser).new(content).parse
      domain_name = name || result.domain_name
      EventStorm::Result.new(
        domain: EventStorm::DomainBuilder.new(result, name: domain_name).build,
        dsl: EventStorm::DslGenerator.new(result, name: domain_name).generate,
        warnings: result.warnings
      )
    end
  end
end
