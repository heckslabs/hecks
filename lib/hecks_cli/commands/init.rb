Hecks::CLI.handle(:init) do |inv|
  name = inv.args.first
  name ||= Hecks::Utils.sanitize_constant(File.basename(Dir.pwd))
  write_or_diff("bluebook.hec", domain_template(name))
  write_or_diff("verbs.txt", "# Add custom action verbs here (one per line)\n# WordNet handles most English verbs automatically\n")
  write_or_diff(".hecks_version", "")
  say "Initialized Hecks domain: #{name}", :green
  say "  bluebook.hec — define your domain here"
  say "  verbs.txt   — add custom action verbs (optional)"
  say ""
  say "Next steps:"
  say "  hecks console           # edit interactively"
  say "  hecks build             # generate the domain gem"
end
