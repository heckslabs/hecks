module RuboCop
  module Cop
    module Hecks
      # Flags a transport detail inside the runtime: a network or process library, a reach into
      # `Hecks::Adapters`, or a read of the process's environment, arguments or standard input.
      #
      # The runtime runs the domain and nothing else; HTTP, Lambda, the shell and the environment
      # belong to the adapters behind a hecksagon's ports, which call into the runtime and never
      # the other way round. An adapter registers itself with the runtime when it loads.
      #
      # @example
      #   require "net/http"                       # bad
      #   Adapters::Folder.new                     # bad
      #   ENV["HECKS_ENVIRONMENT"]                 # bad
      #   Ports::Loading.bootstrap                 # good
      class NoTransportInRuntime < Base
        MSG = "`%<code>s` puts a transport detail inside the runtime. Move it into an adapter " \
              "under `lib/hecks/adapters/` and let the adapter call in, or pass the value in at boot.".freeze

        # Libraries that speak to the network, the shell or another process.
        TRANSPORT_LIBRARIES = %r{\A(net/|uri\z|open-uri\z|socket\z|rack|webrick\z|open3\z|aws-sdk|faraday\z)}

        # Paths a runtime file must not load: adapters and the command line live outside it.
        OUTSIDE_PATHS = %r{(\A|/)(adapters|cli)(/|\z)}

        # @!method library_require(node)
        def_node_matcher :library_require, <<~PATTERN
          (send nil? :require (str $_))
        PATTERN

        # @!method relative_require(node)
        def_node_matcher :relative_require, <<~PATTERN
          (send nil? :require_relative (str $_))
        PATTERN

        # @!method process_input?(node)
        def_node_matcher :process_input?, <<~PATTERN
          (const {nil? cbase} {:ENV :ARGV :STDIN})
        PATTERN

        # @!method adapters_namespace?(node)
        def_node_matcher :adapters_namespace?, <<~PATTERN
          (const {nil? cbase (const {nil? cbase} :Hecks)} :Adapters)
        PATTERN

        # Flags a require of a transport library, or of a file under adapters or the command line.
        #
        # @param node [RuboCop::AST::SendNode] the call being visited
        # @return [void]
        def on_send(node)
          flagged = library_require(node)&.match?(TRANSPORT_LIBRARIES) ||
                    relative_require(node)&.match?(OUTSIDE_PATHS)
          add_offense(node, message: format(MSG, code: node.source)) if flagged
        end

        # Flags `ENV`, `ARGV`, `STDIN` and any `Hecks::Adapters` reference.
        #
        # @param node [RuboCop::AST::ConstNode] the constant being visited
        # @return [void]
        def on_const(node)
          return unless process_input?(node) || adapters_namespace?(node)

          add_offense(node, message: format(MSG, code: node.source))
        end

        # Flags `$stdin`.
        #
        # @param node [RuboCop::AST::Node] the global variable being visited
        # @return [void]
        def on_gvar(node)
          return unless node.children.first == :$stdin

          add_offense(node, message: format(MSG, code: node.source))
        end
      end
    end
  end
end
