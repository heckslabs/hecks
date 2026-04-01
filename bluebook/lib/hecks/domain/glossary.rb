require_relative "glossary/text_helpers"
require_relative "glossary/statement_builders"

module Hecks
  # Hecks::DomainGlossary
  #
  # Walks the domain IR and produces plain-English statements that describe
  # the domain model. Each aggregate, its attributes, value objects, entities,
  # commands, queries, validations, invariants, and policies are rendered as
  # human-readable sentences. Use it to validate your reasoning about the domain
  # with non-technical stakeholders.
  #
  # Also generates a "Relationships" section for cross-aggregate references
  # and a "Domain Policies" section for domain-level reactive policies.
  #
  #   Hecks::DomainGlossary.new(domain).generate  # => Array<String> of lines
  #   Hecks::DomainGlossary.new(domain).print      # prints to stdout
  #   domain.glossary                               # convenience method
  #
  class DomainGlossary
    include TextHelpers
    include StatementBuilders

    # @param domain [Hecks::DomainModel::Domain] the domain IR to describe
    def initialize(domain)
      @domain = domain
    end

    # Generate the full glossary as an array of markdown-formatted lines.
    # Includes a title, per-aggregate sections, domain-level policies,
    # and a relationships section.
    #
    # @return [Array<String>] lines of markdown text
    def generate
      lines = []
      lines << "# #{@domain.name} Domain Glossary"
      lines << ""

      @domain.aggregates.each do |agg|
        lines.concat(describe_aggregate(agg))
        lines << ""
      end

      unless @domain.policies.empty?
        lines << "## Domain Policies"
        lines << ""
        @domain.policies.each do |pol|
          lines << policy_statement(@domain.name, pol)
        end
        lines << ""
      end

      lines.concat(describe_relationships)
      lines.concat(describe_ubiquitous_language)
      lines
    end

    # Print the full glossary to stdout.
    #
    # @return [nil]
    def print
      puts generate.join("\n")
      nil
    end

    # Generate glossary lines for a single aggregate only.
    #
    # @param agg [Hecks::DomainModel::Aggregate] the aggregate to describe
    # @return [Array<String>] lines of markdown text for this aggregate
    def generate_for(agg)
      describe_aggregate(agg)
    end

    # Print the glossary for a single aggregate to stdout.
    #
    # @param agg [Hecks::DomainModel::Aggregate] the aggregate to describe
    # @return [nil]
    def print_for(agg)
      puts generate_for(agg).join("\n")
      nil
    end

    private

    # Build glossary lines for one aggregate, including its attributes,
    # value objects, entities, commands, queries, validations, invariants,
    # and aggregate-level policies.
    #
    # @param agg [Hecks::DomainModel::Aggregate] the aggregate to describe
    # @return [Array<String>] lines of markdown text
    def describe_aggregate(agg)
      lines = []
      lines << "## #{agg.name}"
      lines << ""

      agg.attributes.each do |attr|
        lines << attribute_statement(agg.name, attr)
      end

      agg.value_objects.each do |vo|
        lines << "#{an(vo.name)} is part of #{an(agg.name, capitalize: false)}."
        vo.attributes.each do |attr|
          lines << "  #{an(vo.name)} has #{article(attr.name.to_s)} #{attr.name} (#{attr.type})."
        end
        vo.invariants.each do |inv|
          lines << "  #{inv.message}. (invariant)"
        end
      end

      agg.entities.each do |ent|
        lines << "#{an(ent.name)} is an entity within #{an(agg.name, capitalize: false)}, with its own identity."
        ent.attributes.each do |attr|
          lines << "  #{an(ent.name)} has #{article(attr.name.to_s)} #{attr.name} (#{attr.type})."
        end
        ent.invariants.each do |inv|
          lines << "  #{inv.message}. (invariant)"
        end
      end

      agg.commands.each_with_index do |cmd, i|
        lines << command_statement(agg.name, cmd, agg.events[i])
      end

      agg.queries.each do |q|
        lines << "You can look up #{pluralize(agg.name)} by #{humanize(q.name)}. (query)"
      end

      agg.validations.each do |v|
        lines << "#{an(agg.name)} must have #{article(v.field.to_s)} #{v.field}. (validation)" if v.rules[:presence]
        v.rules.each do |rule, value|
          next if rule == :presence
          lines << "#{an(agg.name)}'s #{v.field} must be #{rule}: #{value}. (validation)"
        end
      end

      agg.invariants.each do |inv|
        lines << "#{inv.message}. (invariant)"
      end

      agg.policies.each do |pol|
        lines << policy_statement(agg.name, pol)
      end

      lines
    end
  end
end
