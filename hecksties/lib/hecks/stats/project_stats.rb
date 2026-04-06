  # Hecks::Stats::ProjectStats
  #
  # Collects metrics across all domains in a project directory.
  # Finds *_domain/Bluebook files, loads each, and aggregates stats.
  #
  #   stats = ProjectStats.new("/path/to/project")
  #   puts stats.summary
  #
module Hecks::Stats

  class ProjectStats
    def initialize(project_root)
      @root = project_root
    end

    def domains
      @domains ||= find_domain_files.map do |path|
        Kernel.load(path)
        domain = Hecks.last_domain
        DomainStats.new(domain)
      end
    end

    def to_h
      domain_data = domains.map(&:to_h)
      {
        domains:        domain_data.size,
        aggregates:     domain_data.sum { |d| d[:aggregates] },
        commands:       domain_data.sum { |d| d[:commands] },
        events:         domain_data.sum { |d| d[:events] },
        attributes:     domain_data.sum { |d| d[:attributes] },
        value_objects:  domain_data.sum { |d| d[:value_objects] },
        entities:       domain_data.sum { |d| d[:entities] },
        policies:       domain_data.sum { |d| d[:policies] },
        queries:        domain_data.sum { |d| d[:queries] },
        specifications: domain_data.sum { |d| d[:specifications] },
        validations:    domain_data.sum { |d| d[:validations] },
        invariants:     domain_data.sum { |d| d[:invariants] },
        lifecycles:     domain_data.sum { |d| d[:lifecycles] },
        services:       domain_data.sum { |d| d[:services] },
        subscribers:    domain_data.sum { |d| d[:subscribers] },
        references:     aggregate_references(domain_data),
        actors:         domain_data.flat_map { |d| d[:actors] }.uniq,
        per_domain:     domain_data
      }
    end

    def summary
      lines = []
      domains.each { |d| lines << d.summary << "" }

      h = to_h
      lines << "Project Totals"
      lines << "=============="
      lines << ""
      lines << "  Domains:        #{h[:domains]}"
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
      lines << "  All Actors: #{h[:actors].join(', ')}"
      lines.join("\n")
    end

    private

    def find_domain_files
      Dir[File.join(@root, "**/Bluebook")].sort
    end

    def aggregate_references(domain_data)
      {
        composition:   domain_data.sum { |d| d[:references][:composition] },
        aggregation:   domain_data.sum { |d| d[:references][:aggregation] },
        cross_context: domain_data.sum { |d| d[:references][:cross_context] }
      }
    end
  end
end
