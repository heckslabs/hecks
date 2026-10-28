require_relative "corpus_tasks"
require_relative "static_directory"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `CorpusRun` asks of the working tree to preview a static site: serve one
      # directory of files on the loopback address only, until the server is stopped.
      #
      # The server hook is the one `CorpusTasks` has, so a spec replaces every server the same way.
      module Previewing
        # Every operation this family carries out.
        OPERATIONS = %w[preview].freeze

        # The port the preview listens on when none is named.
        DEFAULT_PORT = 4580

        # The only address the preview binds: it carries no authentication.
        HOST = "127.0.0.1".freeze

        module_function

        # Serves the directory.
        #
        # @param operation [String] `preview`
        # @param held [Hash] the `CorpusRun` record's fields: `port` and `directory`
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param shell [#capture, nil] unused
        # @return [String] a note that the server stopped
        # @raise [ConsoleCapture::Failure] when the directory is not named or is not a directory
        def call(operation, held, tree, shell: nil)
          _ = [operation, shell, tree]
          fields = held.transform_values { |value| value.is_a?(Hash) ? value[:value] : value }
          root = directory(fields[:directory])
          port = fields[:port] || DEFAULT_PORT
          warn "previewing #{root} on http://#{HOST}:#{port}/ - no authentication; do not expose beyond localhost"
          (CorpusTasks.web_server || method(:serve)).call(app: StaticDirectory.new(root), port: port, host: HOST)
          "previewed on port #{port}, now stopped"
        end

        # @param app [#call] the Rack app
        # @param port [Integer] the port
        # @param host [String] the address to bind
        # @return [void]
        def serve(app:, port:, host:)
          require "rackup"
          Rackup::Server.start(app: app, Host: host, Port: port, server: "webrick")
        end

        # @param named [String, nil] the directory the run names
        # @return [String] its absolute path
        # @raise [ConsoleCapture::Failure] when it is not named or is not a directory
        def directory(named)
          path = File.expand_path(named.to_s)
          return path if !named.to_s.empty? && File.directory?(path)

          raise ConsoleCapture::Failure, "preview needs directory=<path> naming a directory, not #{named.inspect}"
        end
      end
    end
  end
end
