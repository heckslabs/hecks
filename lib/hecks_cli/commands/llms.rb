Hecks::CLI.register_command(:llms, "Generate AI-readable llms.txt summary of the domain",
  options: {
    domain:  { type: :string, desc: "Domain gem name or path" },
    version: { type: :string, desc: "Domain version" }
  }
) do
  domain = resolve_domain_option
  next unless domain

  puts Hecks::LlmsGenerator.new(domain).generate
end
