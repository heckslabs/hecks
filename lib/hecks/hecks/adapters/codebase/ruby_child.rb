# frozen_string_literal: true

require_relative "../shell"
require_relative "../console_capture"
require "hecks/tools"

module Hecks
  module Adapters
    module Codebase
      # Runs one of this repository's own tools, by its name in `Hecks::Tools::REGISTRY`.
      #
      # The tool runs in this process from the checkout's root, its output and exit status
      # captured: the gem carries every tool, so nothing is started as a child.
      class RubyChild
        # @param tree [Tree] the checkout the tool belongs to
        def initialize(tree)
          @tree = tree
        end

        # Runs the tool with the arguments and answers what it printed.
        #
        # @param script [String] the tool's name in `Hecks::Tools::REGISTRY`
        # @param args [Array<String>] its arguments
        # @param env [Hash{String => String}] unused; a tool reads this process's environment
        # @return [String] what it wrote to stdout, and to stderr when there was any
        # @raise [ConsoleCapture::Failure] when it ends with a non-zero status; the message is
        #   everything it printed
        def answer(script, *, env: {})
          result = capture(script, *, env: env)
          return printed(result) if result.ok?

          raise ConsoleCapture::Failure, printed(result, "ended with status #{result.status.exitstatus}")
        end

        # Runs the tool with the arguments and answers only what it printed to stdout, for a tool
        # whose stdout is its data and whose stderr is progress.
        #
        # @param script [String] the tool's name in `Hecks::Tools::REGISTRY`
        # @param args [Array<String>] its arguments
        # @param env [Hash{String => String}] unused; a tool reads this process's environment
        # @return [String] its stdout, without the trailing newline
        # @raise [ConsoleCapture::Failure] when it ends with a non-zero status; the message is
        #   everything it printed
        def read(script, *, env: {})
          result = capture(script, *, env: env)
          return result.out.chomp if result.ok?

          raise ConsoleCapture::Failure, printed(result, "ended with status #{result.status.exitstatus}")
        end

        # Runs the tool with the arguments and hands back how it ended.
        #
        # @param script [String] the tool's name in `Hecks::Tools::REGISTRY`
        # @param args [Array<String>] its arguments
        # @param env [Hash{String => String}] unused; a tool reads this process's environment
        # @return [Shell::Result] its output (stderr included) and status
        # @raise [KeyError] when no tool has that name
        def capture(script, *args, env: {}) # rubocop:disable Lint/UnusedMethodArgument
          in_process(script, args)
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
