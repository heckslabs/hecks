require "json"
require "stringio"
require_relative "launcher_line"

module Hecks
  module Adapters
    module Driving
      module Mcp
        # Answers a `run` call: the command is admitted by the server's scope, then run by
        # `CliRunner` itself, so its resolution, parsing, write forwarding, settling and refusals
        # are the launcher's. A role-gated command needs `role:`, as `dispatch` does; a role given
        # is self-asserted and bound for the run. Each run writes one line to the trace. The
        # server's list is admitted across the attached bluebooks (`McpScope::LauncherAdmission`),
        # where `dispatch` admits it against the domain's own bluebook only.
        module LauncherRun
          # The program name the launcher's answers and hints use.
          PROGRAM = "hecks".freeze

          module_function

          # @param args [Hash{String => Object}] the tool call's arguments
          # @return [Hash{Symbol => Object}] `ok`, the exit `status`, the launcher's `answer`, and
          #   `error` when it refused
          # @raise [Runtime::TypeMismatch, Runtime::Unauthorized] when the call is refused before it
          #   runs
          def call(args)
            runtime = Mcp.boot(args["domain"])
            plan    = admitted(runtime, args)
            answer  = launched(runtime, args)
            trace(runtime, plan, args, answer)
            answer
          end

          # The plan of an admitted call, after the caller fields and the role door are checked.
          def admitted(runtime, args)
            Storehouse.require_summary!(args["summary"])
            Storehouse.valid_source!(args["source"])
            Storehouse.valid_caller!(args["role"], args["actor_id"])
            plan = Mcp.scope.admit_launcher_command!(runtime, args["command"], args["args"])
            Storehouse.require_caller_for_role_gated!(plan[:spec], args["role"])
            plan
          end

          # Runs the line through `CliRunner` with the caller bound.
          def launched(runtime, args)
            argv = LauncherLine.argv(args["command"], args["args"], wait: args["wait"] != false, plan: args["plan"] == true)
            err  = StringIO.new
            text, status, reason = Storehouse.with_dispatching_caller(args["role"], args["actor_id"]) do
              CliRunner.call(runtime: runtime, argv: argv, program: PROGRAM, err: err)
            end
            answered(text, status, reason, err.string)
          end

          # The launcher's answer as the tool answers it.
          def answered(text, status, reason, notes)
            answer = { ok: status.zero?, status: status, answer: parsed(text), notes: notes.lines.map(&:chomp) }
            status.zero? ? answer : answer.merge(error: reason || text.to_s)
          end

          # @return [Object] the text parsed when it is JSON, else the text
          def parsed(text)
            JSON.parse(text.to_s)
          rescue JSON::ParserError
            text
          end

          # One trace line under the domain's own bluebook, where `follow` reads.
          def trace(runtime, plan, args, answer)
            domain = Storehouse.bluebook_for(runtime)
            Storehouse.record!(domain.name, tool: "run", outcome: answer.slice(:ok, :error),
                                                             verb: plan[:spec][:command], summary: args["summary"],
                                                             source: args["source"], role: args["role"],
                                                             actor_id: args["actor_id"], surface: "mcp")
          end
        end
      end
    end
  end
end
