Hecks::CLI.register_command(:mcp, "Start MCP server — build domains (default) or serve one (--domain)",
  options: {
    domain:  { type: :string, desc: "Domain gem name or path (serves it as MCP tools)" },
    version: { type: :string, desc: "Domain version" }
  }
) do
  if options[:domain]
    domain = resolve_domain(options[:domain])
    unless domain
      say "Domain not found: #{options[:domain]}", :red
      next
    end
    require "hecks_ai"
    Hecks::MCP::DomainServer.new(domain).run
  else
    require "hecks_ai"
    Hecks::McpServer.new.run
  end
end
