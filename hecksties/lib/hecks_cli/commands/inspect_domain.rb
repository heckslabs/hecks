# Hecks::CLI — inspect command
#
# Shows the full domain definition including business logic, formatted
# for terminal reading. Walks the domain IR to display attributes, value
# objects, entities, lifecycle, commands, events, queries, validations,
# invariants, policies, scopes, specifications, subscribers, and references.
#
#   hecks inspect                          # full domain
#   hecks inspect --aggregate Order        # single aggregate
#   hecks inspect --domain path/to/domain  # explicit domain path
#
require_relative "../domain_inspector"

Hecks::CLI.register_command(:inspect, "Show full domain definition including business logic",
  options: {
    domain:    { type: :string, desc: "Domain gem name or path" },
    aggregate: { type: :string, desc: "Filter to a single aggregate by name" }
  }
) do
  domain = resolve_domain_option
  next unless domain

  output = Hecks::CLI::DomainInspector.new(domain).generate(aggregate: options[:aggregate])
  say output
end
