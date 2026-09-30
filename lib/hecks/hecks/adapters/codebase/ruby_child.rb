# frozen_string_literal: true

require "rbconfig"
require_relative "../shell"
require_relative "../console_capture"
require_relative "../../../tools"

module Hecks
  module Adapters
    module Codebase
      # Runs one of this repository's own scripts from the checkout's root.
      #
      # A script whose body lives in `Hecks::Tools` runs in this process from the checkout's root,
      # its output and exit status captured: the gem carries it, so no `bin/` script is needed. Any
      # other script runs as a child, which is told not to print the 3.0 notice, so what it prints
      # is only its own report.
      class RubyChild
        # What a child is told, so its output is only its report.
        QUIET = { "HECKS_NO_3_0_NOTICE" => "1" }.freeze

        # @param tree [Tree] the checkout the script belongs to
        # @param shell [#capture, nil] starts the process; a `Shell` when nil
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

        # Runs `bin/<script>` with the arguments and answers only what it printed to stdout, for a
        # script whose stdout is its data and whose stderr is progress.
        #
        # @param script [String] the script's name in `bin/`
        # @param args [Array<String>] its arguments
        # @param env [Hash{String => String}] variables to set for it
        # @return [String] its stdout, without the trailing newline
        # @raise [ConsoleCapture::Failure] when it ends with a non-zero status; the message is
        #   everything it printed
        def read(script, *, env: {})
          result = capture(script, *, env: env)
          return result.out.chomp if result.ok?

          raise ConsoleCapture::Failure, printed(result, "ended with status #{result.status.exitstatus}")
        end

        # Runs the script with the arguments and hands back how it ended.
        #
        # @param script [String] the script's name in `bin/`
        # @param args [Array<String>] its arguments
        # @param env [Hash{String => String}] variables to set for it
        # @return [Shell::Result] its output (stderr included, for a tool run here) and status
        def capture(script, *args, env: {})
          return in_process(script, args) if Tools.tool?(script)

          @shell.capture(RbConfig.ruby, @tree.path("bin", script), *args, env: QUIET.merge(env), chdir: @tree.root)
        end

        private

        def in_process(script, args)
          code = nil
          outcome = ConsoleCapture.capture { code = Tools.run(script, args, root: @tree.root) }
          Shell::Result.new(outcome.output, "", Status.new(code))
        end

        # How a tool run in this process ended, answering as a `Process::Status` does.
        Status = Struct.new(:exitstatus) do
          # @return [Boolean] whether it ended with status 0
          def success? = exitstatus.zero?
        end

        def printed(result, otherwise = "")
          text = [result.out, result.err].map(&:strip).reject(&:empty?).join("\n")
          text.empty? ? otherwise : text
        end
      end
    end
  end
end
