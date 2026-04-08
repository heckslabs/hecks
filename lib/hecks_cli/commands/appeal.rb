# Hecks::CLI appeal command
#
# Launches the HecksAppeal IDE server. Discovers hecks projects in the
# given directory (or current directory) and opens the browser interface.
#
#   hecks appeal                    # serve current directory
#   hecks appeal /path/to/project   # serve specific project
#
Hecks::CLI.register_command(:appeal, "Launch the HecksAppeal IDE",
  args: ["PATH..."]
) do |*args|
  appeal = File.expand_path("../../../bin/appeal", __dir__)
  exec appeal, *args
end
