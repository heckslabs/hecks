# frozen_string_literal: true

require "rbconfig"
require_relative "../shell"
require_relative "../console_capture"

module Hecks
  module Adapters
    module Codebase
      # Runs one of this repository's own scripts in a child Ruby process, from the checkout's root.
      #
      # Most tools of Codebase are reached in this process. A child is used where isolation is the
      # point or the script owns its process: a comment linter that reads files with its own
      # options, or a generator that boots several throwaway domains. The child is told not to
      # print the 3.0 notice, so what it prints is only its own report.
      class RubyChild
        # What a child is told, so its output is only its report.
        QUIET = { "HECKS_NO_3_0_NOTICE" => "1" }.freeze

        # @param tree [Tree] the checkout the script belongs to
        # @param shell [#capture] starts the process; a `Shell` when nil
        def initialize(tree, shell: nil)
          @tree = tree
          @shell = shell || Shell.new
        end

        # Runs `bin/<script>` with the arguments and answers what it printed.
        #
        # @param script [String] the script's name in `bin/`
        # @param args [Array<String>] its arguments
        # @param env [Hash{String => String}] variables to set for it
        # @return [String] what it wrote to stdout, and to stderr when there was any
        # @raise [ConsoleCapture::Failure] when it ends with a non-zero status; the message is
        #   everything it printed
        def answer(script, *, env: {})
          result = capture(script, *, env: env)
          return printed(result) if result.ok?

          raise ConsoleCapture::Failure, printed(result, "ended with status #{result.status.exitstatus}")
        end

        # Runs `bin/<script>` with the arguments and hands back how it ended.
        #
        # @param script [String] the script's name in `bin/`
        # @param args [Array<String>] its arguments
        # @param env [Hash{String => String}] variables to set for it
        # @return [Shell::Result] its output and status
        def capture(script, *, env: {})
          @shell.capture(RbConfig.ruby, @tree.path("bin", script), *, env: QUIET.merge(env), chdir: @tree.root)
        end

        private

        def printed(result, otherwise = "")
          text = [result.out, result.err].map(&:strip).reject(&:empty?).join("\n")
          text.empty? ? otherwise : text
        end
      end
    end
  end
end
