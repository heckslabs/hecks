# frozen_string_literal: true

require_relative "shell"
require_relative "claude_executable"

module Hecks
  module Adapters
    # A {Shell} that runs `claude` from where {ClaudeExecutable} finds it, so a step started with a
    # `PATH` that lacks `claude` still reaches it, or is refused by name when nothing does. Any
    # other program, and any `claude` given as a path, runs as asked.
    class ClaudeResolvingShell
      # @param executable [#resolve] finds the `claude` program, raising when there is none
      # @param shell [Shell] runs the program
      def initialize(executable: ClaudeExecutable.new, shell: Shell.new)
        @executable = executable
        @shell = shell
      end

      # @param command [Array<String>] the program and its arguments; a `claude` in it is resolved
      # @return [Shell::Result] what the program said
      # @raise [ConsoleCapture::Failure] when `claude` is asked for and is nowhere
      def capture(*command, env: {}, chdir: nil)
        @shell.capture(*resolved(command), env: env, chdir: chdir)
      end

      private

      def resolved(command)
        at = command.first(4).index(ClaudeExecutable::COMMAND) if %w[claude nice].include?(command.first)
        return command unless at

        command.dup.tap { |line| line[at] = @executable.resolve }
      end
    end
  end
end
