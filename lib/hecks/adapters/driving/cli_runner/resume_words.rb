module Hecks
  module Adapters
    module Driving
      module CliRunner
        # The launcher word `resume <run>` (ADR 0163, plan step 31): continues a saga that faulted
        # from the stage it faulted in. The saga saved its arguments and the stage; the process
        # manager's `resumes` list names the command that re-runs that stage, and that command is
        # dispatched with the saved arguments through the ordinary line path.
        module ResumeWords
          SAGA = "GateAndBoard".freeze
          USAGE = "resume <run>  continue a GateAndBoard saga that faulted, from the stage it faulted in".freeze

          # The answer to `resume <run>`, or nil when the line is not a resume.
          def resume(scope, argv)
            return unless argv.first == "resume"
            return { answer: [resume_usage, ExitStatus::USAGE] } unless argv[1] && booted?(scope)

            outcome = scope[:runtime].saga_interpreter.resume(scope[:bluebook].name, SAGA, argv[1])
            return { answer: [resume_refusal(outcome), ExitStatus::REFUSED] } unless outcome[:resumed]

            resume_stage(scope, outcome)
          end

          # Whether the line runs against a booted domain: a describe-only runtime (the usage path)
          # has no saga interpreter, so a resume there answers its usage rather than failing.
          def booted?(scope)
            scope[:runtime].respond_to?(:saga_interpreter)
          end

          # Dispatches the stage's resume command with the saved arguments, or refuses when the
          # stage declares none.
          def resume_stage(scope, outcome)
            command = resume_command(scope[:bluebook], outcome[:stage])
            unless command
              return { answer: ["resume refused: stage #{outcome[:stage]} declares no resume command",
                                ExitStatus::REFUSED] }
            end

            line = [command, *outcome[:arguments].map { |key, value| "#{key}=#{value}" }]
            text, status = CliRunner.call(runtime: scope[:runtime], argv: line, program: scope[:program])
            { answer: [text, status] }
          end

          # The command the process manager's `resumes` list names for a stage, as a bang line.
          def resume_command(bluebook, stage)
            process_manager = bluebook.process_managers.find { |pm| pm.name == SAGA }
            entry = process_manager&.resumes&.find { |line| line.start_with?("#{stage}=") }
            entry && "#{entry.split("=", 2).last}!"
          end

          # The reason a resume refuses: the saga is missing, or it is not waiting for a person.
          def resume_refusal(outcome)
            "resume refused: #{outcome[:reason]}"
          end

          # The usage line of `resume`.
          def resume_usage
            "usage: resume <run>  (continues a GateAndBoard saga that faulted, from the stage it faulted in)"
          end
        end
      end
    end
  end
end
