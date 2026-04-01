Hecks::CLI.register_command(:init, "Initialize a Hecks domain in the current directory",
  options: {
    force: { type: :boolean, desc: "Overwrite without prompting" }
  },
  args: ["NAME"]
) do |name = nil|
  name ||= Hecks::Utils.sanitize_constant(File.basename(Dir.pwd))
  write_or_diff("#{name}Bluebook", domain_template(name))
  write_or_diff("verbs.txt", "# Add custom action verbs here (one per line)\n# WordNet handles most English verbs automatically\n")
  write_or_diff(".hecks_version", "")
  say "Initialized Hecks domain: #{name}", :green
  say "  domain.rb   — define your domain here"
  say "  verbs.txt   — add custom action verbs (optional)"
  say ""
  say "Next steps:"
  say "  hecks domain workshop   # edit interactively"
  say "  hecks domain build     # generate the domain gem"
end
