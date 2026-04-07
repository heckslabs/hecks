# Hecks::CLI::DomainInspector
#
# Formats a Domain IR into comprehensive, readable terminal output showing
# the full domain definition including business logic. Walks all aggregates,
# domain-level policies, services, views, workflows, sagas, actors, and
# glossary rules.
#
#   inspector = Hecks::CLI::DomainInspector.new(domain)
#   inspector.generate                    # => String
#   inspector.generate(aggregate: "Order") # => String (single aggregate)
#
Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Cli::CliFormatters,
  base_dir: File.expand_path("domain_inspector", __dir__)
)

module Hecks
  class CLI
    # Hecks::CLI::DomainInspector
    #
    # Formats a Domain IR into comprehensive, readable terminal output covering all aggregates and domain elements.
    #
    class DomainInspector
      # @param domain [Hecks::DomainModel::Structure::Domain]
      def initialize(domain)
        @domain = domain
      end

      # Generate the full inspection output.
      #
      # @param aggregate [String, nil] optional aggregate name filter
      # @return [String] formatted domain inspection
      def generate(aggregate: nil)
        lines = []
        lines << "Domain: #{@domain.name}"
        lines << "#{'=' * (8 + @domain.name.length)}"
        lines << ""

        aggregates = @domain.aggregates
        if aggregate
          aggregates = aggregates.select { |a| a.name == aggregate }
          if aggregates.empty?
            lines << "No aggregate named '#{aggregate}' found."
            return lines.join("\n")
          end
        end

        aggregates.each do |agg|
          lines.concat(AggregateFormatter.new(agg).format)
          lines << ""
        end

        lines.concat(format_domain_policies)
        lines.concat(format_services)
        lines.concat(format_views)
        lines.concat(format_workflows)
        lines.concat(format_sagas)
        lines.concat(format_actors)
        lines.concat(format_glossary_rules)

        lines.join("\n")
      end

      private

      def format_domain_policies
        return [] if @domain.policies.empty?
        lines = ["Domain Policies:"]
        @domain.policies.each do |pol|
          async_note = pol.async ? " [async]" : ""
          if pol.reactive?
            cond = pol.condition ? " when #{Hecks::Utils.block_source(pol.condition)}" : ""
            lines << "  #{pol.name}: #{pol.event_name} -> #{pol.trigger_command}#{async_note}#{cond}"
          else
            body = Hecks::Utils.block_source(pol.block)
            lines << "  #{pol.name}: guard#{async_note} — #{body}"
          end
        end
        lines << ""
      end

      def format_services
        return [] if @domain.services.empty?
        lines = ["Services:"]
        @domain.services.each do |svc|
          name = svc.respond_to?(:name) ? svc.name : svc.to_s
          lines << "  #{name}"
        end
        lines << ""
      end

      def format_views
        return [] if @domain.views.empty?
        lines = ["Views:"]
        @domain.views.each do |view|
          name = view.respond_to?(:name) ? view.name : view.to_s
          lines << "  #{name}"
        end
        lines << ""
      end

      def format_workflows
        return [] if @domain.workflows.empty?
        lines = ["Workflows:"]
        @domain.workflows.each do |wf|
          name = wf.respond_to?(:name) ? wf.name : wf.to_s
          lines << "  #{name}"
        end
        lines << ""
      end

      def format_sagas
        return [] if @domain.sagas.empty?
        lines = ["Sagas:"]
        @domain.sagas.each do |saga|
          name = saga.respond_to?(:name) ? saga.name : saga.to_s
          lines << "  #{name}"
        end
        lines << ""
      end

      def format_actors
        return [] if @domain.actors.empty?
        lines = ["Actors:"]
        @domain.actors.each do |actor|
          lines << "  #{actor.name}"
        end
        lines << ""
      end

      def format_glossary_rules
        return [] if @domain.glossary_rules.empty?
        lines = ["Glossary Rules:"]
        @domain.glossary_rules.each do |rule|
          term = rule.respond_to?(:term) ? rule.term : rule[:term]
          defn = rule.respond_to?(:definition) ? rule.definition : rule[:definition]
          lines << "  #{term}: #{defn}"
        end
        lines << ""
      end
    end
  end
end
