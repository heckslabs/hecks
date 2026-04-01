# Hecks::Stats CLI Command
#
# Registers the `hecks stats` command. Loads all domain files in the
# current project and prints comprehensive metrics.
#
#   hecks stats
#   hecks stats --json
#
# stats merged into hecksties

Hecks::CLI.register_command(:stats, "Show comprehensive domain statistics",
  options: {
    json: { type: :boolean, desc: "Output as JSON" }
  }
) do
  require "json" if options[:json]
  project_root = Dir.pwd
  stats = Hecks::Stats::ProjectStats.new(project_root)
  if options[:json]
    puts JSON.pretty_generate(stats.to_h)
  else
    puts stats.summary
  end
end
