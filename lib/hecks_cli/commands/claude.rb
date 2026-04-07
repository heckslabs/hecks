# Hecks::CLI :claude command
# Starts file watchers and launches Claude Code in one step.
# Usage: hecks claude [ARGS...]
Hecks::CLI.register_command(:claude, "Start file watchers and launch Claude Code",
  args: ["ARGS..."]
) do |*args|
  script = ::Gem.bin_path("hecks", "hecks_claude")
  exec script, *args
rescue ::Gem::Exception
  say "hecks_claude not found. Is the hecks gem installed?", :red
end
