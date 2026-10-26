require_relative "corpus_tasks"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `CorpusRun` asks of the working tree to open the Composer: serve its editor
      # over one domain directory, on the loopback address only, until the server is stopped.
      #
      # The server hook is the one `CorpusTasks` has, so a spec replaces both servers the same way.
      module Composing
        # Every operation this family carries out.
        OPERATIONS = %w[compose].freeze

        # The port the editor listens on when none is named.
        DEFAULT_PORT = 4570

        # The directory the editor opens when none is named, relative to the checkout.
        DEFAULT_WORKSPACE = "examples/pizzas/bluebook".freeze

        # The only address the editor binds: it carries no authentication.
        HOST = "127.0.0.1".freeze

        module_function

        # Opens the editor.
        #
        # @param operation [String] `compose`
        # @param held [Hash] the `CorpusRun` record's fields: `port`, `domains` (the directory) and
        #   `agent` (`claude`, or `fake` for a scripted assistant)
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param shell [#capture, nil] unused
        # @return [String] a note that the server stopped
        def call(operation, held, tree, shell: nil)
          _ = [operation, shell]
          require "hecks/composer/web"
          fields = held.transform_values { |value| value.is_a?(Hash) ? value[:value] : value }
          workspace = File.expand_path(fields[:domains] || DEFAULT_WORKSPACE, tree.root)
          port = fields[:port] || DEFAULT_PORT
          warn "composer over #{workspace} on http://#{HOST}:#{port}/composer - no authentication, " \
               "no CSRF protection, no caller identity; do not expose beyond localhost"
          app = Composer::Web.app(workspace: workspace, agents: Composer::Workbench.agents_named(fields[:agent]))
          (CorpusTasks.web_server || method(:serve)).call(app: app, port: port, host: HOST)
          "composed on port #{port}, now stopped"
        end

        # @param app [#call] the Rack app
        # @param port [Integer] the port
        # @param host [String] the address to bind
        # @return [void]
        def serve(app:, port:, host:)
          require "rackup"
          Rackup::Server.start(app: app, Host: host, Port: port, server: "webrick")
        end
      end
    end
  end
end
