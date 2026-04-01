# Hecks::CLI tour command
#
# Launches a guided walkthrough of the sketch -> play -> build loop.
# Demonstrates domain modeling from aggregate creation through play mode.
#
#   hecks tour
#
Hecks::CLI.register_command(:tour, "Guided walkthrough of the workshop") do
  Hecks::Workshop::WorkshopRunner.new.tour
end
