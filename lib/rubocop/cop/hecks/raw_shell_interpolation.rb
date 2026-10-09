module RuboCop
  module Cop
    module Hecks
      # Flags a shell command built by interpolating a value into one string.
      #
      # `system("rm -rf #{dir}")` hands the shell a string it re-parses, so a value with a space
      # or a metacharacter changes the command. The array form (`system("rm", "-rf", dir)`)
      # passes each argument as-is. An interpolation wrapped in `Shellwords.escape` or
      # `shellescape` is left alone.
      #
      # @example
      #   system("git checkout #{branch}")         # bad
      #   system("git", "checkout", branch)        # good
      class RawShellInterpolation < Base
        MSG = "`%<call>s` runs a string with `\#{}` interpolated into it, so the shell re-parses the value. " \
              "Pass the command as separate arguments (`%<call>s(\"cmd\", arg)`), or wrap the value in " \
              "`Shellwords.escape`.".freeze

        XSTR_MSG = "A backtick or `%x` command with `\#{}` interpolated into it is re-parsed by the shell. " \
                   "Use `IO.popen([\"cmd\", arg], &:read)` or `Open3.capture2(\"cmd\", arg)`, or wrap the " \
                   "value in `Shellwords.escape`.".freeze

        SHELL_CALLS = %i[system exec spawn].freeze
        OPEN3_CALLS = %i[capture2 capture2e capture3 popen2 popen2e popen3 pipeline pipeline_r pipeline_w
                         pipeline_rw pipeline_start].freeze

        # @!method open3_receiver?(node)
        def_node_matcher :open3_receiver?, "(const {nil? cbase} :Open3)"

        # @!method escaped?(node)
        def_node_matcher :escaped?, <<~PATTERN
          {(send (const {nil? cbase} :Shellwords) {:escape :shellescape :join :shelljoin} ...)
           (send _ {:shellescape :shelljoin})}
        PATTERN

        # Flags a single-string command with a raw interpolation.
        #
        # @param node [RuboCop::AST::SendNode] the call being visited
        # @return [void]
        def on_send(node)
          return unless shell_call?(node)

          command = command_argument(node)
          return unless command&.dstr_type? && raw_interpolation?(command)

          add_offense(node, message: format(MSG, call: node.method_name))
        end

        # Flags a backtick or `%x` literal with a raw interpolation.
        #
        # @param node [RuboCop::AST::StrNode] the command literal being visited
        # @return [void]
        def on_xstr(node)
          return unless raw_interpolation?(node)

          add_offense(node, message: XSTR_MSG)
        end

        private

        def shell_call?(node)
          return SHELL_CALLS.include?(node.method_name) if node.receiver.nil? || node.receiver.cbase_type?

          open3_receiver?(node.receiver) && OPEN3_CALLS.include?(node.method_name)
        end

        # The lone command string, after an optional leading env hash; nil when it passes argv.
        def command_argument(node)
          args = node.arguments.drop_while(&:hash_type?)
          args.first if args.size == 1
        end

        def raw_interpolation?(node)
          node.each_child_node(:begin).any? { |part| !escaped?(part.children.first) }
        end
      end
    end
  end
end
