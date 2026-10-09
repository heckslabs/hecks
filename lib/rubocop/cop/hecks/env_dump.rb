module RuboCop
  module Cop
    module Hecks
      # Flags a secret leaving the process in output: the whole environment printed, or a
      # `*_KEY` / `*_SECRET` / `*_TOKEN` / `*_PASSWORD` variable interpolated into a string.
      #
      # An interpolated secret ends up in a log line, a failure message or a command line. Reading
      # one into a local (or an HTTP header) is fine; building a string around it is not. Restoring
      # the environment in a spec (`saved = ENV.to_h`) is not output, so it is left alone.
      #
      # @example
      #   puts ENV.to_h                                  # bad
      #   warn "using #{ENV.fetch("API_TOKEN")}"         # bad
      #   headers["Authorization"] = ENV.fetch("API_TOKEN")  # good
      class EnvDump < Base
        MSG_DUMP = "This prints the whole environment, which carries every secret the process holds. " \
                   "Print only the variable names you need.".freeze
        MSG_SECRET = "`%<read>s` is a secret read into a string, so it will land in a log line or a message. " \
                     "Pass it straight to the call that needs it instead of interpolating it.".freeze

        OUTPUT_CALLS = %i[puts p pp print warn].freeze
        SECRET_NAME = /(KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL)/i

        # @!method whole_env?(node)
        def_node_matcher :whole_env?, <<~PATTERN
          {(const {nil? cbase} :ENV) (send (const {nil? cbase} :ENV) {:to_h :to_a :to_s :inspect})}
        PATTERN

        # @!method env_read(node)
        def_node_matcher :env_read, <<~PATTERN
          (send (const {nil? cbase} :ENV) {:[] :fetch} (str $_) ...)
        PATTERN

        # Flags the whole environment handed to an output call.
        #
        # @param node [RuboCop::AST::SendNode] the call being visited
        # @return [void]
        def on_send(node)
          return unless node.receiver.nil? && OUTPUT_CALLS.include?(node.method_name)
          return unless node.arguments.any? { |argument| whole_env?(argument) }

          add_offense(node, message: MSG_DUMP)
        end

        # Flags a secret variable interpolated into a string.
        #
        # @param node [RuboCop::AST::BeginNode] the `#{}` part being visited
        # @return [void]
        def on_begin(node)
          return unless interpolation?(node)

          read = node.children.filter_map { |child| secret_read(child) }.first
          add_offense(node, message: format(MSG_SECRET, read: read)) if read
        end

        private

        def interpolation?(node)
          %i[dstr dsym xstr].include?(node.parent&.type)
        end

        def secret_read(node)
          name = env_read(node)
          node.source if name&.match?(SECRET_NAME)
        end
      end
    end
  end
end
