require_relative "llms_generator/aggregate_describer"
require_relative "llms_generator/validation_describer"
require_relative "llms_generator/policy_describer"

module Hecks
  # Hecks::LlmsGenerator
  #
  # Walks the domain IR and produces an AI-readable plain text summary suitable
  # for llms.txt files. Includes domain name, aggregates with attributes and
  # types, commands with parameters, queries, specifications, policies with
  # event-command mappings, validation rules, invariants, and reactive flow
  # chains.
  #
  #   Hecks::LlmsGenerator.new(domain).generate  # => String (plain text)
  #   Hecks::LlmsGenerator.new(domain).print     # prints to stdout
  #
  class LlmsGenerator
    include AggregateDescriber
    include ValidationDescriber
    include PolicyDescriber

    # @param domain [Hecks::DomainModel::Structure::Domain] the domain IR
    def initialize(domain)
      @domain = domain
    end

    # Generate the full llms.txt content as a single string.
    #
    # @return [String] AI-readable plain text summary of the domain
    def generate
      domain_name = @domain.name
      lines = []
      lines << "# #{domain_name} Domain"
      lines << ""
      lines << "This document describes the #{domain_name} domain model for use by AI assistants."
      lines << ""

      @domain.aggregates.each do |agg|
        lines.concat(describe_aggregate(agg))
        lines << ""
      end

      lines.concat(describe_domain_policies)
      lines.concat(describe_reactive_flows)

      lines.join("\n")
    end

    # Print the llms.txt content to stdout.
    #
    # @return [nil]
    def print
      puts generate
      nil
    end
  end
end
