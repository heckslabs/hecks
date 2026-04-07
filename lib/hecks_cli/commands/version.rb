Hecks::CLI.register_command(:version, "Show Hecks version, or domain version (--domain)",
  options: {
    domain:  { type: :string, desc: "Domain gem name or path" },
    version: { type: :string, desc: "Domain version" }
  }
) do
  if options[:domain]
    domain = resolve_domain(options[:domain])
    unless domain
      say "Domain not found: #{options[:domain]}", :red
      next
    end
    spec = ::Gem.loaded_specs[domain.gem_name]
    if spec
      say "#{domain.name}: #{spec.version}"
    else
      dir = File.directory?(options[:domain]) ? options[:domain] : "."
      versioner = Hecks::Versioner.new(dir)
      say "#{domain.name}: #{versioner.current || "not built yet"}"
    end
  else
    say "hecks #{Hecks::VERSION}"
  end
end
