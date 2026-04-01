Hecks::CLI.register_command(:version_tag, "Tag current domain as a named version snapshot",
  args: ["VERSION"],
  options: {
    domain: { type: :string, desc: "Domain gem name or path" }
  }
) do |version|
  domain = resolve_domain_option
  next unless domain

  if Hecks::DomainVersioning.exists?(version, base_dir: Dir.pwd)
    say "Version #{version} already exists. Choose a different version label.", :red
    next
  end

  path = Hecks::DomainVersioning.tag(version, domain, base_dir: Dir.pwd)
  say "Tagged #{domain.name} as v#{version}", :green
  say "  Snapshot: #{path}"
end
