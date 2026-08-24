require "open3"
require "json"
require "timeout"

require_relative "../../ports/agent"

module Hecks
  module Adapters
    # THE REAL `agent` FULFILLMENT — shells out to the `claude` CLI
    # itself, `claude -p --output-format json`, one process per call.
    # `Ports::Agent`'s own scripted double (`spec/fixtures/scripted_
    # agent.{adapter,rb}`) is the deterministic sibling every spec binds
    # instead, the same relationship `SecureRandomIdentity` already has
    # to `SequentialIdentity`.
    #
    # THIS FILE OWNS TRANSPORT ONLY — spawning the process, unwrapping
    # the CLI's own JSON envelope (`{"result": "..."}`) down to the
    # model's raw text, and parsing THAT text as JSON. It hands back a
    # plain Hash. Whether that Hash has the keys a caller asked for, and
    # whether its values are within the closed vocabularies this port
    # recognizes (a critique's `kind`, a proposal's `verb` pattern) is
    # `Ports::Agent::Answers`' job, not this file's — see `ports/agent.rb`'s
    # own header for why that split is load-bearing.
    #
    # `Open3.capture2` with an explicit argv array, never a shell string
    # — the same shape every other subprocess call in this repo already
    # uses (`bin/rust_conformance`), and the reason `claude` being
    # shell-aliased to `claude --dangerously-skip-permissions` in a
    # human's own terminal never reaches this code at all: an argv spawn
    # invokes the real binary directly, no shell, no alias.
    #
    # `--allowedTools ""` — this adapter asks a question and reads back
    # text; it never wants the model reaching for a tool mid-answer.
    module ClaudeCode
      TIMEOUT_SECONDS = 120

      SYSTEM_PREFIX = "You are assisting a domain-modeling interview for the hecks " \
                      "event-sourced framework. Reply with EXACTLY ONE JSON object, no prose " \
                      "before or after it, no markdown code fence. "

      module_function

      # THE NEXT BEST QUESTION. `state` is whatever
      # `Interview::Session#declaration`/`#gaps` produced — passed
      # through as JSON, not reformatted, so this adapter never
      # re-derives what the session already knows.
      def ask(state:, asked:)
        call(
          system:  SYSTEM_PREFIX + "Given the domain model so far, ask the single best next " \
                                   'discovery question. Reply as {"questions": [{"text": "...", "because": "..."}]} ' \
                                   "with exactly one entry. Never repeat a question already asked.",
          payload: { state: state, already_asked: asked }
        )
      end

      # PROSE -> PROPOSED DECLARATIONS.
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

      # WHAT IS WRONG WITH THIS AS A MODEL — closed to the same kind
      # vocabulary `Ports::Agent::CRITIQUE_KINDS` declares, spelled out
      # here too since the system prompt is the only place the model
      # itself ever sees that list.
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

      # VOCABULARY HELP. Named `suggest_name`, not `name` — see
      # `Ports::Agent#suggest_name`'s own comment for why `name` is
      # never a safe module-function name here.
      def suggest_name(meaning:, kind:, near:)
        call(
          system:  SYSTEM_PREFIX + "Suggest a name for a #{kind} meaning \"#{meaning}\", distinct from " \
                                   'the names already in use nearby. Reply as {"names": [{"name": "...", "because": ' \
                                   '"...", "rejected": ["...", "..."]}]} with exactly one entry.',
          payload: { meaning: meaning, kind: kind, near: near }
        )
      end

      # ── transport ───────────────────────────────────────────────────

      def call(system:, payload:)
        stdout, status = Timeout.timeout(TIMEOUT_SECONDS) {
          Open3.capture2(
            "claude", "-p", "--output-format", "json",
            "--append-system-prompt", system, "--allowedTools", "",
            stdin_data: JSON.generate(payload)
          )
        }
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
