require_relative "dsl_serializer/type_helpers"
require_relative "dsl_serializer/rule_serializer"
require_relative "dsl_serializer/behavior_serializer"
require_relative "dsl_serializer/aggregate_serializer"

module Hecks
  # Hecks::DslSerializer
  #
  # Serializes a Domain IR back into DSL source code. The output is valid
  # Ruby that can be eval'd to reconstruct the domain.
  #
  #   DslSerializer.new(domain).serialize
  #   # => 'Hecks.domain "Pizzas" do ...'
  #
  class DslSerializer
    include TypeHelpers
    include RuleSerializer
    include BehaviorSerializer
    include AggregateSerializer

    def initialize(domain)
      @domain = domain
    end

    # @return [String] valid Ruby DSL source code
    def serialize
      lines = ["Hecks.domain \"#{@domain.name}\" do"]
      lines << "  description \"#{@domain.description}\"" if @domain.description
      @domain.aggregates.each_with_index do |agg, i|
        lines << "" if i > 0
        lines.concat(serialize_aggregate(agg))
      end
      @domain.policies.each { |pol| lines.concat(serialize_domain_policy(pol)) }
      lines << "end"
      lines.join("\n") + "\n"
    end
  end
end
