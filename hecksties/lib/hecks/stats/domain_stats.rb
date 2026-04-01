module Hecks::Stats

  # Hecks::Stats::DomainStats
  #
  # Collects metrics for a single Hecks domain.
  #
  #   stats = DomainStats.new(domain)
  #   stats.to_h[:aggregates]  # => 5
  #   stats.to_h[:commands]    # => 14
  #
  class DomainStats
    def initialize(domain)
      @domain = domain
    end

    def to_h
      aggs = @domain.aggregates
      {
        name:            @domain.name,
        aggregates:      aggs.size,
        attributes:      aggs.sum { |a| a.attributes.size },
        commands:        aggs.sum { |a| a.commands.size },
        events:          aggs.sum { |a| a.events.size },
        value_objects:   aggs.sum { |a| a.value_objects.size },
        entities:        aggs.sum { |a| a.entities.size },
        policies:        aggs.sum { |a| a.policies.size } + @domain.policies.size,
        queries:         aggs.sum { |a| a.queries.size },
        specifications:  aggs.sum { |a| a.specifications.size },
        validations:     aggs.sum { |a| a.validations.size },
        invariants:      aggs.sum { |a| a.invariants.size },
        references:      references_breakdown(aggs),
        actors:          (@domain.actors || []).map(&:name),
        services:        @domain.services.size,
        lifecycles:      aggs.count { |a| a.lifecycle },
        subscribers:     aggs.sum { |a| a.subscribers.size }
      }
    end

    def summary
      h = to_h
      lines = []
      lines << "#{h[:name]} Domain"
      lines << "=" * (h[:name].length + 7)
      lines << ""
      lines << "  Aggregates:     #{h[:aggregates]}"
      lines << "  Attributes:     #{h[:attributes]}"
      lines << "  Commands:       #{h[:commands]}"
      lines << "  Events:         #{h[:events]}"
      lines << "  Value Objects:  #{h[:value_objects]}"
      lines << "  Entities:       #{h[:entities]}"
      lines << "  Policies:       #{h[:policies]}"
      lines << "  Queries:        #{h[:queries]}"
      lines << "  Specifications: #{h[:specifications]}"
      lines << "  Validations:    #{h[:validations]}"
      lines << "  Invariants:     #{h[:invariants]}"
      lines << "  Lifecycles:     #{h[:lifecycles]}"
      lines << "  Services:       #{h[:services]}"
      lines << "  Subscribers:    #{h[:subscribers]}"
      lines << ""
      refs = h[:references]
      lines << "  References:"
      lines << "    Composition:   #{refs[:composition]}"
      lines << "    Aggregation:   #{refs[:aggregation]}"
      lines << "    Cross-context: #{refs[:cross_context]}"
      lines << ""
      lines << "  Actors: #{h[:actors].join(', ')}" unless h[:actors].empty?
      lines.join("\n")
    end

    private

    def references_breakdown(aggs)
      all_refs = aggs.flat_map { |a| a.references || [] }
      {
        total:         all_refs.size,
        composition:   all_refs.count { |r| r[:kind] == :composition },
        aggregation:   all_refs.count { |r| r[:kind] == :aggregation },
        cross_context: all_refs.count { |r| r[:kind] == :cross_context }
      }
    end
  end
end
