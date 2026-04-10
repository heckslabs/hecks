# Hecks::CLI -- inspect command
#
# Shows the full domain definition including business logic, formatted
# for terminal reading. Walks the domain IR to display attributes, value
# objects, entities, lifecycle, commands, events, queries, validations,
# invariants, policies, scopes, specifications, subscribers, and references.
#
#   hecks inspect                          # full domain
#   hecks inspect --aggregate Order        # single aggregate
#   hecks inspect --domain path/to/domain  # explicit domain path
#   hecks inspect --format json            # JSON output for tooling
#
Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Cli::CliFormatters,
  base_dir: File.expand_path("..", __dir__)
)

Hecks::CLI.handle(:inspect) do |inv|
  domain = resolve_domain_option
  next unless domain

  if options[:format] == "json"
    require "json"
    aggs = domain.aggregates
    if options[:aggregate]
      aggs = aggs.select { |a| a.name == options[:aggregate] }
    end
    result = {
      domain: domain.name,
      aggregates: aggs.map { |a| aggregate_to_hash(a) }
    }
    say JSON.pretty_generate(result)
    next
  end

  output = Hecks::CLI::DomainInspector.new(domain).generate(aggregate: options[:aggregate])
  say output
end

def aggregate_to_hash(agg)
  h = {
    name: agg.name,
    attributes: agg.attributes.map { |a| { name: a.name.to_s, type: a.type.to_s } }
  }
  h[:value_objects] = agg.value_objects.map(&:name) unless agg.value_objects.empty?
  h[:entities] = agg.entities.map(&:name) unless agg.entities.empty?
  h[:commands] = agg.commands.map { |c| { name: c.name, attributes: c.attributes.map { |a| { name: a.name.to_s, type: a.type.to_s } } } } unless agg.commands.empty?
  h[:events] = agg.events.map(&:name) unless agg.events.empty?
  h[:queries] = agg.queries.map(&:name) unless agg.queries.empty?
  h[:policies] = agg.policies.map(&:name) unless agg.policies.empty?
  if agg.respond_to?(:lifecycle) && agg.lifecycle
    lc = agg.lifecycle
    h[:lifecycle] = { field: lc.field.to_s, default: lc.default_state.to_s }
  end
  h
end
