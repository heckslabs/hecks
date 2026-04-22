Hecks::CLI.handle(:init) do |inv|
  name = inv.args.first
  name ||= Hecks::Utils.sanitize_constant(File.basename(Dir.pwd))
  stem = name.to_s.gsub(/(?<=[a-z])(?=[A-Z])/, "_").downcase
  write_or_diff("#{stem}.bluebook", domain_template(name))
  write_or_diff("verbs.txt", "# Add custom action verbs here (one per line)\n# WordNet handles most English verbs automatically\n")
  write_or_diff(".hecks_version", "")
  say "Initialized Hecks domain: #{name}", :green
  say "  #{stem}.bluebook — define your domain here"
  say "  verbs.txt   — add custom action verbs (optional)"
  say ""
  say "Next steps:"
  say "  hecks console           # edit interactively"
  say "  hecks build             # generate the domain gem"
end
