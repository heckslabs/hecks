require_relative "../../../runtime/errors"
require_relative "../../../text"

module Hecks
  module Adapters
    module Driving
      class McpScope
        # What a commands server lets `run` reach. The requested name and every allowed name are
        # resolved by the launcher's own resolution (`CliRunner.resolve`), which reads every
        # spelling and the attached bluebooks, and the commands they reach are compared. So an
        # allowed `Landing.retire!` admits `landing.retire` and `Delivery::Landing.Retire`, and a
        # name that reaches nothing, or reaches a question or a word such as `help`, admits nothing.
        # `dispatch` still admits through `Storehouse.verbs_for`, which reads only the domain's own
        # bluebook, so an attached command on the list passes `run` and not `dispatch`.
        module LauncherAdmission
          # The program name resolution is read under.
          PROGRAM = "hecks".freeze

          # The argument whose declaration makes a command one only the command line runs.
          CONFIRM = "confirm".freeze

          module_function

          # @param runtime [Runtime::Dispatcher] the booted domain
          # @param command [String, nil] the command as the caller named it
          # @param args [Hash, nil] its arguments, checked by `ArgumentPolicy`
          # @param listed [Hash{String => Array, nil}] each allowed name and the command it reaches
          #   ({.listed})
          # @param label [String] how the server describes its mode, for a refusal
          # @return [Hash] the launcher's plan of the command
          # @raise [Runtime::TypeMismatch] when the command or an argument is refused
          def admit!(runtime, command, args, listed:, label:)
            plan = command_plan(runtime, command)
            refuse!(command, label, "names no command the launcher runs: #{launcher_says(runtime, command)}") unless plan
            unless listed.value?(identity(plan))
              refuse!(command, label, "runs only #{COMMANDS_VARIABLE}: #{listed.keys.join(", ")}")
            end
            refuse!(command, label, "declares confirm, so it runs only on the command line") if confirmed?(plan)
            ArgumentPolicy.admit!(args, label)
            plan
          end

          # The launcher's plan of a command, or nil when the name runs no command.
          def command_plan(runtime, name)
            plan = CliRunner.resolve(runtime, [name.to_s], PROGRAM)
            plan if !plan[:answer] && !plan[:asking] && plan[:spec]
          end

          # The first line the launcher answers a name that runs no command, such as its help or the
          # refusal of a command written without its `!`.
          def launcher_says(runtime, name)
            answer = CliRunner.resolve(runtime, [name.to_s], PROGRAM)[:answer]
            answer ? Hecks::Text.first_line(answer.first.to_s) : "it reaches a question"
          end

          # Each allowed name with the bluebook and command it reaches, nil when it reaches none.
          #
          # @param runtime [Runtime::Dispatcher] the booted domain
          # @param allowed [Array<String>] the server's `HECKS_SERVER_COMMANDS`
          # @return [Hash{String => Array(String, String), nil}]
          def listed(runtime, allowed)
            allowed.to_h { |name| [name, command_plan(runtime, name)&.then { |plan| identity(plan) }] }
          end

          # @return [Array(String, String)] the bluebook and the command a plan reaches
          def identity(plan) = [plan[:bluebook].name, plan[:spec][:command]]

          def confirmed?(plan)
            Array(plan[:spec][:arguments]).any? { |argument| argument[:path].to_s.split(".").first == CONFIRM }
          end

          def refuse!(command, label, why)
            raise Runtime::TypeMismatch, "command: #{command.to_s.inspect} is refused: this server runs in #{label} and #{why}"
          end
        end
      end
    end
  end
end
