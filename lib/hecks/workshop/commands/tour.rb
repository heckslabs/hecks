# Hecks::CLI tour command
#
# Launches a guided walkthrough. Without flags, runs the domain modeler's
# sketch -> play -> build loop. With --architecture, runs a contributor's
# walkthrough of the framework internals.
#
#   hecks tour
#   hecks tour --architecture
#
Hecks::CLI.register_command(
  :tour,
  "Guided walkthrough of the workshop (--architecture for internals)",
  options: { architecture: { type: :boolean, default: false, desc: "Contributor walkthrough of framework components" } }
) do
  if options[:architecture]
    Hecks::ArchitectureTour.new.start
  else
    Hecks::Workshop::WorkshopRunner.new.tour
  end
end
