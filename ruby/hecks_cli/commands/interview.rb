Hecks::Chapters.load_aggregates(
  Hecks::Cli::CliInternals,
  base_dir: File.expand_path("..", __dir__)
)

Hecks::CLI.handle(:interview) do |inv|
  say "Welcome to Hecks! Let's build your domain together.", :green
  say ""

  interviewer = Hecks::Interviewer.new(
    ask: method(:ask),
    say: method(:say)
  )

  dsl_source = interviewer.run
  next say("Interview cancelled.", :yellow) unless dsl_source

  # Extract domain name from the generated DSL to name the file
  domain_name = dsl_source[/Hecks\.domain "(\w+)"/, 1] || "MyDomain"
  write_or_diff("#{domain_name}Bluebook", dsl_source)
  write_or_diff("verbs.txt", "# Add custom action verbs here (one per line)\n# WordNet handles most English verbs automatically\n")

  say ""
  say "Next steps:", :green
  say "  hecks validate          # check your domain"
  say "  hecks build             # generate the domain gem"
  say "  hecks console           # edit interactively"
end
