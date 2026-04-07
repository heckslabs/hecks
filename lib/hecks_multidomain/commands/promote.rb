Hecks::CLI.register_command(:promote, "Extract an aggregate into its own domain",
  args: ["AGGREGATE"]
) do |aggregate_name|

  domain = resolve_domain_option
  next unless domain

  agg_name = domain_constant_name(aggregate_name)
  agg = domain.aggregates.find { |a| a.name == agg_name }
  unless agg
    say "No aggregate named #{agg_name} in #{domain.name}", :red
    say "Available: #{domain.aggregates.map(&:name).join(', ')}"
    next
  end

  # Build a standalone domain for the promoted aggregate
  new_domain = Hecks::DomainModel::Structure::Domain.new(
    name: agg_name, aggregates: [agg], custom_verbs: []
  )
  new_file = "#{domain_snake_name(agg_name)}_domain.rb"
  File.write(new_file, Hecks::DslSerializer.new(new_domain).serialize)
  say "Wrote #{new_file} (#{agg.attributes.size} attributes, #{agg.commands.size} commands)", :green

  # Re-save the original domain without the promoted aggregate
  remaining = domain.aggregates.reject { |a| a.name == agg_name }
  updated = Hecks::DomainModel::Structure::Domain.new(
    name: domain.name, aggregates: remaining, custom_verbs: domain.custom_verbs
  )
  source_file = find_domain_file || "Bluebook"
  File.write(source_file, Hecks::DslSerializer.new(updated).serialize)
  say "#{agg_name} removed from #{domain.name} (#{source_file} updated)", :green
end
