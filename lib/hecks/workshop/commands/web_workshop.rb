Hecks::CLI.register_command(:web_workshop, "Start the browser-based workshop",
  args: ["NAME"],
  options: {
    gate: { type: :numeric, default: 4567, desc: "Server port" },
    domain: { type: :string, desc: "Path to Bluebook file" },
    enable_console: { type: :boolean, default: false, desc: "Enable console endpoint (disabled by default for security)" }
  }
) do |name = nil|
  port = options.fetch(:port, 4567)
  domain = options[:domain]
  enable_console = options.fetch(:enable_console, false)
  Hecks::Workshop::WebRunner.new(name: name, gate: port, domain: domain, enable_console: enable_console).run
end
