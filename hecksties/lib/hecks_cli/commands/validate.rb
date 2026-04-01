Hecks::CLI.register_command(:validate, "Validate the domain definition",
  options: { domain: { type: :string, desc: "Domain gem name or path" } }
) do
  domain = resolve_domain_option
  return unless domain
  validator = Hecks::Validator.new(domain)
  if validator.valid?
    say "Domain is valid", :green
    say ""
    say "Aggregates:"
    domain.aggregates.each do |agg|
      say "  #{agg.name}"
      say "    Attributes:     #{agg.attributes.map(&:name).join(', ')}"
      say "    Value Objects:  #{agg.value_objects.map(&:name).join(', ')}" unless agg.value_objects.empty?
      say "    Entities:       #{agg.entities.map(&:name).join(', ')}" unless agg.entities.empty?
      say "    Commands:       #{agg.commands.map(&:name).join(', ')}" unless agg.commands.empty?
      say "    Events:         #{agg.events.map(&:name).join(', ')}" unless agg.events.empty?
      say "    Policies:       #{agg.policies.map(&:name).join(', ')}" unless agg.policies.empty?
    end
  else
    say "Domain validation failed:", :red
    validator.errors.each { |e| say "  - #{e}", :red }
  end

  unless validator.warnings.empty?
    say ""
    say "Warnings:", :yellow
    validator.warnings.each { |w| say "  - #{w}", :yellow }
  end

  print_mother_earth_report(validator)
end
