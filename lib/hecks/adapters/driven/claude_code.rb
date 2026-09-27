require "open3"
require "json"
require "timeout"

require_relative "../../ports/agent"

module Hecks
  module Adapters
    # Real `agent` fulfillment: one `claude -p --output-format json` process per call.
    # Transport only; shape and vocabulary checks belong to `Ports::Agent::Answers`.
    module ClaudeCode
      TIMEOUT_SECONDS = 120

      SYSTEM_PREFIX = "You are assisting a domain-modeling interview for the hecks " \
                      "event-sourced framework. Reply with EXACTLY ONE JSON object, no prose " \
                      "before or after it, no markdown code fence. ".freeze

      module_function

      def ask(state:, asked:)
        call(
          system:  SYSTEM_PREFIX + "Given the domain model so far, ask the single best next " \
                                   'discovery question. Reply as {"questions": [{"text": "...", "because": "..."}]} ' \
                                   "with exactly one entry. Never repeat a question already asked.",
          payload: { state: state, already_asked: asked }
        )
      end

      def interpret(prose:, state:)
        call(
          system:  SYSTEM_PREFIX + "Given the domain model so far and a sentence the human just said, " \
                                   "propose zero or more declarations that capture what the sentence names as domain " \
                                   "fact. A verb must be fully qualified as Chapter::Aggregate.Command. Reply as " \
                                   '{"proposals": [{"verb": "...", "rationale": "...", "arguments": ' \
                                   '[{"name": "...", "field": "...", "value": "..."}]}]}. If the sentence carries no ' \
                                   'declaration (a question back, a clarification), reply {"proposals": []}.',
          payload: { state: state, prose: prose }
        )
      end

      def critique(declared:, refusals:, findings:)
        kinds = Ports::Agent::CRITIQUE_KINDS.join(", ")
        call(
          system:  SYSTEM_PREFIX + "Given a domain declaration, the refusals it already triggered, and " \
                                   "the mechanical findings already reported, judge it on TASTE — do not restate what is " \
                                   "already known. Only use one of these kinds: #{kinds}. Only use severity error or " \
                                   'warning. Reply as {"findings": [{"kind": "...", "severity": "...", "subject": "...", ' \
                                   '"message": "..."}]}. Reply {"findings": []} if there is nothing worth saying.',
          payload: { declared: declared, refusals: refusals, findings: findings }
        )
      end

      # Named `suggest_name`, not `name`: `name` is never a safe module-function name here.
      def suggest_name(meaning:, kind:, near:)
        call(
          system:  SYSTEM_PREFIX + "Suggest a name for a #{kind} meaning \"#{meaning}\", distinct from " \
                                   'the names already in use nearby. Reply as {"names": [{"name": "...", "because": ' \
                                   '"...", "rejected": ["...", "..."]}]} with exactly one entry.',
          payload: { meaning: meaning, kind: kind, near: near }
        )
      end

      # Argv spawn, never a shell, so a `claude` shell alias cannot apply; no tools are allowed.
      def call(system:, payload:)
        stdout, status = Timeout.timeout(TIMEOUT_SECONDS) do
          Open3.capture2(
            "claude", "-p", "--output-format", "json",
            "--append-system-prompt", system, "--allowedTools", "",
            stdin_data: JSON.generate(payload)
          )
        end
        raise Ports::Agent::Unavailable, "claude exited #{status.exitstatus}: #{stdout}" unless status.success?

        unwrap(stdout)
      rescue Timeout::Error
        raise Ports::Agent::Unavailable, "claude did not answer within #{TIMEOUT_SECONDS}s"
      rescue Errno::ENOENT => e
        raise Ports::Agent::Unavailable, "claude is not on PATH: #{e.message}"
      end

      def unwrap(stdout)
        envelope = JSON.parse(stdout)
        result = envelope["result"]
        raise Ports::Agent::ValidationError, "no \"result\" in the claude envelope: #{stdout}" unless result

        JSON.parse(result)
      rescue JSON::ParserError => e
        raise Ports::Agent::ValidationError, "claude's reply was not JSON: #{e.message}\n#{stdout}"
      end
    end
  end
end
