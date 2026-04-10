# Hecks::CLI :claude command
# Starts file watchers and launches Claude Code in one step.
# Usage: hecks claude [ARGS...]
Hecks::CLI.handle(:claude) do |inv|
  script = ::Gem.bin_path("hecks", "hecks_claude")
  exec script, *inv.args
rescue ::Gem::Exception
  say "hecks_claude not found. Is the hecks gem installed?", :red
end
