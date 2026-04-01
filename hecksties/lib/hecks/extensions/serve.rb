# HecksServe
#
# HTTP and JSON-RPC server extension for Hecks domains. Serves domains
# over REST and JSON-RPC via WEBrick. Includes OpenAPI, JSON Schema, and
# RPC discovery generators for API documentation.
#
# When registered, adds a +.serve(port:)+ singleton method to the domain
# module that starts a DomainServer on the specified port. The server
# auto-generates CRUD routes for all aggregates plus query endpoints.
#
# Sub-components:
# - {Hecks::HTTP::DomainServer} -- WEBrick REST server with CORS
# - {Hecks::HTTP::RpcServer} -- JSON-RPC 2.0 server
# - {Hecks::HTTP::RouteBuilder} -- generates route definitions from aggregates
# - {Hecks::Connections::HttpConnection} -- connection wrapper for boot blocks
#
# Future gem: hecks_serve
#
#   require "hecks_serve"
#   Hecks::HTTP::DomainServer.new(domain, port: 3000).run
#
Hecks.describe_extension(:http,
  description: "REST and JSON-RPC server with OpenAPI docs",
  config: { gate: { default: 9292, desc: "HTTP port" }, rpc: { default: false, desc: "Enable JSON-RPC mode" } },
  wires_to: :command_bus)

# Register the HTTP extension. Adds a +.serve+ method to the domain module
# that instantiates and runs a DomainServer.
#
# @param domain_mod [Module] the domain module constant (e.g. CatsDomain)
# @param domain [Hecks::Domain] the parsed domain definition
# @param _runtime [Hecks::Runtime] the runtime instance (unused)
Hecks.register_extension(:http) do |domain_mod, domain, _runtime|
  domain_mod.define_singleton_method(:serve) do |port: 9292|
    Hecks::HTTP::DomainServer.new(domain, gate: port).run
  end
end

module Hecks
  # HTTP server components for serving Hecks domains over REST and JSON-RPC.
  module HTTP
    autoload :DomainServer,       "hecks/extensions/serve/domain_server"
    autoload :MultiDomainServer,  "hecks/extensions/serve/multi_domain_server"
    autoload :RpcServer,          "hecks/extensions/serve/rpc_server"
    autoload :RouteBuilder,       "hecks/extensions/serve/route_builder"
    autoload :CommandBusPort,     "hecks/extensions/serve/command_bus_port"
    autoload :OpenapiGenerator,   "hecks/generators/docs/openapi_generator"
    autoload :RpcDiscovery,       "hecks/generators/docs/rpc_discovery"
    autoload :JsonSchemaGenerator, "hecks/generators/docs/json_schema_generator"
  end

  # Connection wrappers for boot-time wiring of external interfaces.
  module Connections
    autoload :HttpConnection, "hecks/extensions/serve/connection"
  end
end
