# Hecks::CLI -- validate command
#
# Validates a domain definition and reports errors, warnings, and
# an aggregate summary. Supports JSON output for tooling.
#
#   hecks validate
#   hecks validate --domain path/to/domain
#   hecks validate --format json
#
Hecks::CLI.register_command(:validate, "Validate the domain definition",
  options: {
    domain: { type: :string, desc: "Domain gem name or path" },
    format: { type: :string, desc: "Output format: text (default) or json" }
  }
) do
  domain = resolve_domain_option
  return unless domain
  validator = Hecks::Validator.new(domain)
  valid = validator.valid?

  if options[:format] == "json"
    require "json"
    result = {
      valid: valid,
      domain: domain.name,
      aggregates: domain.aggregates.map do |agg|
        entry = { name: agg.name, attributes: agg.attributes.map(&:name).map(&:to_s) }
        entry[:value_objects] = agg.value_objects.map(&:name) unless agg.value_objects.empty?
        entry[:entities] = agg.entities.map(&:name) unless agg.entities.empty?
        entry[:commands] = agg.commands.map(&:name) unless agg.commands.empty?
        entry[:events] = agg.events.map(&:name) unless agg.events.empty?
        entry[:policies] = agg.policies.map(&:name) unless agg.policies.empty?
        entry
      end,
      errors: validator.errors,
      warnings: validator.warnings
    }
    say JSON.pretty_generate(result)
    next
  end

  if valid
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
    validator.errors.each do |e|
      say "  - #{e}", :red
      say "    Fix: #{e.hint}", :cyan if e.respond_to?(:hint) && e.hint
    end
  end

  unless validator.warnings.empty?
    say ""
    say "Warnings:", :yellow
    validator.warnings.each do |w|
      say "  - #{w}", :yellow
      say "    Fix: #{w.hint}", :cyan if w.respond_to?(:hint) && w.hint
    end
  end

  print_world_concerns_report(validator)
end
