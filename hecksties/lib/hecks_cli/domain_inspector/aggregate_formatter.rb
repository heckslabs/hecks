# Hecks::CLI::DomainInspector::AggregateFormatter
#
# Formats a single aggregate from the domain IR into readable terminal output.
# Covers attributes, value objects, entities, lifecycle, commands, events,
# queries, validations, invariants, policies, scopes, specifications,
# subscribers, computed attributes, and references.
#
# Each concern is extracted into its own module under aggregate_formatter/.
#
#   formatter = AggregateFormatter.new(aggregate)
#   formatter.format  # => Array<String>
#
require_relative "secondary_formatters"
require_relative "aggregate_formatter/structure_formatters"
require_relative "aggregate_formatter/behavior_formatters"
require_relative "aggregate_formatter/rule_formatters"
require_relative "aggregate_formatter/lifecycle_formatter"

module Hecks
  class CLI
    class DomainInspector
      # Hecks::CLI::DomainInspector::AggregateFormatter
      #
      # Formats a single aggregate from the domain IR into readable terminal output covering all IR sections.
      #
      class AggregateFormatter
        include SecondaryFormatters
        include StructureFormatters
        include BehaviorFormatters
        include RuleFormatters
        include LifecycleFormatter

        # @param agg [Hecks::DomainModel::Structure::Aggregate]
        def initialize(agg)
          @agg = agg
        end

        # @return [Array<String>] formatted lines for this aggregate
        def format
          lines = []
          lines << "Aggregate: #{@agg.name}"
          lines << "=" * (11 + @agg.name.length)
          lines << ""
          lines.concat(format_attributes)
          lines.concat(format_computed_attributes)
          lines.concat(format_value_objects)
          lines.concat(format_entities)
          lines.concat(format_lifecycle)
          lines.concat(format_commands)
          lines.concat(format_events)
          lines.concat(format_queries)
          lines.concat(format_validations)
          lines.concat(format_invariants)
          lines.concat(format_policies)
          lines.concat(format_scopes)
          lines.concat(format_specifications)
          lines.concat(format_subscribers)
          lines.concat(format_references)
          lines
        end
      end
    end
  end
end
