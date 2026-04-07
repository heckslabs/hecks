# Hecks::CLI glossary command
#
# Prints the domain glossary to stdout. With --export, writes glossary.md.
#
#   hecks glossary
#   hecks glossary --export
#   hecks glossary --domain path/to/domain
#
Hecks::CLI.register_command(:glossary, "Print the domain glossary",
  options: {
    domain: { type: :string, desc: "Domain gem name or path" },
    export: { type: :boolean, desc: "Write glossary.md to disk", default: false }
  }
) do
  domain = resolve_domain_option
  next unless domain

  glossary = Hecks::DomainGlossary.new(domain)
  content = glossary.generate.join("\n")

  if options[:export]
    path = File.join(Dir.pwd, "glossary.md")
    File.write(path, content + "\n")
    say "Wrote #{path}", :green
  else
    say content
  end
end
