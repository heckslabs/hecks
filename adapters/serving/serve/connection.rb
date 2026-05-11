module Hecks
  module Connections
    # Hecks::Connections::HttpConnection
    #
    # Connection wrapper that packages the HTTP REST server as a +listens_to+
    # connection for declarative boot blocks. Wraps a {Hecks::HTTP::DomainServer}
    # instance and provides +start+ to begin serving HTTP requests.
    #
    # Used internally when a domain declares an HTTP listener in its boot block.
    # The connection is instantiated with the domain definition, runtime, and
    # optional port, then started to begin handling requests.
    #
    #   # In a domain boot block:
    #   listens_to :http, port: 3000
    #
    class HttpConnection
      # Create a new HTTP connection wrapping a DomainServer.
      #
      # Instantiates a {Hecks::HTTP::DomainServer} configured with the given
      # domain and port. The server is not started until {#start} is called.
      #
      # @param domain [Hecks::Domain] the domain definition to serve
      # @param runtime [Hecks::Runtime] the runtime instance (passed through
      #   but not directly used by this connection; the DomainServer boots
      #   its own runtime internally)
      # @param port [Integer] the TCP port to listen on (default: 9292)
      # @return [HttpConnection] a new connection ready to start
      def initialize(domain, runtime, port: 9292)
        @server = HTTP::DomainServer.new(domain, gate: port)
      end

      # Start the WEBrick HTTP server and begin handling requests.
      #
      # This is a blocking call -- it runs the server's event loop until
      # the process receives an INT signal (Ctrl-C).
      #
      # @return [void]
      def start
        @server.run
      end
    end
  end
end
