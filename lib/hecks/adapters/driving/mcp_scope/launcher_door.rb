require_relative "launcher_admission"

module Hecks
  module Adapters
    module Driving
      class McpScope
        # The part of a scope that holds `run` to its list: which tools a server serves, what a
        # command `run` may run, and the refusal an unrestricted server answers for `run`, which it
        # does not serve.
        module LauncherDoor
          # The tools only a commands server serves: an unrestricted server has no command list to
          # hold `run` to, so it does not serve it.
          COMMANDS_ONLY_TOOLS = %w[run].freeze

          # @param name [String] a tool's name
          # @return [Boolean] whether this server serves the tool
          def permits_tool?(name) = restricted? ? served_tools.include?(name) : !COMMANDS_ONLY_TOOLS.include?(name)

          # The launcher's plan of a command `run` may run: it is on the list, by any launcher
          # spelling, declares no `confirm`, and its arguments pass the argument policy
          # (`LauncherAdmission`).
          #
          # @param runtime [Runtime::Dispatcher] the booted domain
          # @param command [String, nil] the command as the caller named it
          # @param args [Hash, nil] the arguments the caller gave it
          # @return [Hash] the plan `CliRunner.resolve` answered
          # @raise [Runtime::TypeMismatch] when the command or an argument is refused
          def admit_launcher_command!(runtime, command, args = nil)
            LauncherAdmission.admit!(runtime, command, args, listed: launcher_listed(runtime), label: mode_label)
          end

          # @param name [String] the tool asked for
          # @return [Hash] the refusal of a tool only a commands server serves
          def commands_only_refusal(name)
            { ok: false, error: "#{name.inspect} is refused: only a server in #{COMMANDS} mode serves it" }
          end

          private

          # The allowed names resolved once per booted runtime, which a restricted server keeps.
          def launcher_listed(runtime)
            @launcher_listed = nil unless @launcher_listed&.first.equal?(runtime)
            (@launcher_listed ||= [runtime, LauncherAdmission.listed(runtime, allowed_commands.to_a)]).last
          end
        end
      end
    end
  end
end
