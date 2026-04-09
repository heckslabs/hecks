# Hecks::Capabilities::ClientCommands
#
# Generates a browser-side command dispatcher from the domain IR.
# Infers which commands run client-side vs server-side based on
# aggregate shape: no references + no CRUD = client-side.
#
# Serves the generated JS at /hecks/client.js and mounts a docs
# endpoint at /hecks/docs showing the routing table.
#
#   Hecks.hecksagon "MyApp" do
#     capabilities :client_commands
#   end
#
require_relative "dsl"
require_relative "client_commands/js_generator"
require_relative "client_commands/router"

module Hecks
  module Capabilities
    # Hecks::Capabilities::ClientCommands
    #
    # Client-side command dispatch capability — generates JS from domain IR.
    #
    module ClientCommands
      def self.apply(runtime)
        router = Router.new(runtime.domain)
        generator = JsGenerator.new(runtime.domain, router)

        runtime.instance_variable_set(:@client_commands_router, router)
        runtime.instance_variable_set(:@client_commands_js, generator.generate)
        runtime.define_singleton_method(:client_commands) { @client_commands_router }
        runtime.define_singleton_method(:client_js) { @client_commands_js }

        mount_routes(runtime) if runtime.respond_to?(:static_assets_adapter)
        router
      end

      def self.mount_routes(runtime)
        adapter = runtime.static_assets_adapter
        return unless adapter.respond_to?(:mount)
        js = runtime.client_js
        docs = generate_docs(runtime)

        adapter.mount("/hecks/client.js") do |_req, res|
          res["Content-Type"] = "application/javascript"
          res.body = js
        end

        adapter.mount("/hecks/docs") do |_req, res|
          res["Content-Type"] = "text/html"
          res.body = docs
        end
      end
      private_class_method :mount_routes

      def self.generate_docs(runtime)
        router = runtime.client_commands
        domain = runtime.domain
        lines = ["<html><head><title>#{domain.name} — Command Reference</title>",
                 '<style>body{font-family:monospace;background:#0d0d0d;color:#ccc;padding:2em}',
                 'h1{color:#4361ee}h2{color:#5a7df7;margin-top:2em}',
                 '.client{color:#22c55e}.server{color:#f59e0b}',
                 'code{background:#1a1a2e;padding:2px 6px;border-radius:3px}</style></head><body>',
                 "<h1>#{domain.name} Commands</h1>"]

        domain.aggregates.each do |agg|
          next if agg.commands.empty?
          side = router.client_side?(agg.name) ? "client" : "server"
          lines << "<h2>#{agg.name} <span class=\"#{side}\">(#{side})</span></h2>"
          agg.commands.each do |cmd|
            args = cmd.attributes.map { |a| type_name = a.type.respond_to?(:name) ? a.type.name.split('::').last : a.type.to_s; "#{a.name}: #{type_name}" }
            args_str = args.empty? ? "" : ", { #{args.join(', ')} }"
            lines << "<p><code>Hecks.dispatch(\"#{agg.name}\", \"#{cmd.name}\"#{args_str})</code></p>"
            evt = cmd.respond_to?(:event_names) ? cmd.event_names.first : "#{cmd.name.sub(/^[A-Z]/, &:downcase)}ed"
            lines << "<p style=\"margin-left:2em;color:#666\">→ emits #{evt}</p>"
          end
        end
        lines << "</body></html>"
        lines.join("\n")
      end
      private_class_method :generate_docs
    end
  end
end

Hecks.capability :client_commands do
  description "Browser-side command dispatch generated from domain IR"
  direction :driving
  on_apply do |runtime|
    Hecks::Capabilities::ClientCommands.apply(runtime)
  end
end
