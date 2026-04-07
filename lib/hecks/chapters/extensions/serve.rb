# = Hecks::Chapters::Extensions::ServeChapter
#
# Self-describing sub-chapter for HTTP serving infrastructure:
# domain server, RPC server, route builder, CORS, CSRF, and
# multi-domain server.
#
#   Hecks::Chapters::Extensions::ServeChapter.define(builder)
#
module Hecks
  module Chapters
    module Extensions
      # Hecks::Chapters::Extensions::ServeChapter
      #
      # Bluebook sub-chapter for HTTP serving infrastructure: domain server, RPC server, route builder, and multi-domain server.
      #
      module ServeChapter
        def self.define(b)
          b.aggregate "DomainServer", "WEBrick REST server for a single domain" do
            command("Start") { attribute :port, Integer }
            command("Stop") { attribute :reason, String }
          end

          b.aggregate "MultiDomainServer", "Serves multiple domains on one port" do
            command("Start") { attribute :port, Integer }
          end

          b.aggregate "RpcServer", "JSON-RPC 2.0 server over HTTP" do
            command("HandleRequest") { attribute :method, String; attribute :params, String }
          end

          b.aggregate "RouteBuilder", "Generates route definitions from aggregates" do
            command("BuildRoutes") { attribute :domain_name, String }
          end

          b.aggregate "CommandBusPort", "HTTP-to-command-bus bridge" do
            command("Dispatch") { attribute :command_name, String; attribute :params, String }
          end

          b.aggregate "Connection", "HTTP connection wrapper for boot blocks" do
            command("Connect") { attribute :host, String; attribute :port, Integer }
          end

          b.aggregate "DomainWatcher", "File watcher for auto-reload during serve" do
            command("Watch") { attribute :domain_path, String }
          end
        end
      end
    end
  end
end
