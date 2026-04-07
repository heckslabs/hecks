Hecks::CLI.register_command(:console, "Start the interactive workshop",
  args: ["NAME"]
) do |name = nil|
  Hecks::Workshop::WorkshopRunner.new(name: name).run
end
