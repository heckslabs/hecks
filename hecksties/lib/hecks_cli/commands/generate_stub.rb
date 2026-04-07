Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Cli::CliTools,
  base_dir: File.expand_path("..", __dir__)
)

Hecks::CLI.register_command(:generate_stub, "Scaffold a domain file for hand-editing",
  options: {
    domain: { type: :string,  desc: "Domain gem name or path" },
    force:  { type: :boolean, desc: "Overwrite without prompting" }
  },
  args: ["TYPE", "NAME"]
) do |type, name|
  domain = resolve_domain_option
  next unless domain

  type = type.downcase
  result = Hecks::CLI::StubGenerator.new(domain, type, name).generate
  unless result
    say "Unknown type '#{type}'. Use: command, query, aggregate, workflow, service, policy, specification", :red
    next
  end

  result.each do |path, content|
    write_or_diff(path, content)
  end
end
