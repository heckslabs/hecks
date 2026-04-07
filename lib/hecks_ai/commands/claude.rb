Hecks::CLI.register_command(:claude, "Start file watchers and launch Claude Code",
  args: ["ARGS..."]
) do |*args|
  local = File.expand_path("../../../../bin/hecks_claude", __dir__)
  script = File.exist?(local) ? local : ::Gem.bin_path("hecks", "hecks_claude")
  exec script, *args
rescue ::Gem::Exception
  say "hecks_claude not found. Is the hecks gem installed?", :red
end
