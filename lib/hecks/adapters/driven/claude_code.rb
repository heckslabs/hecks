require "open3"
require "json"
require "timeout"

require_relative "../../ports/agent"

module Hecks
  module Adapters
    # **The real `agent` fulfillment** — shells out to the `claude` CLI
    # itself, `claude -p --output-format json`, one process per call.
    # `Ports::Agent`'s own scripted double (`spec/fixtures/scripted_
    # agent.{adapter,rb}`) is the deterministic sibling every spec binds
    # instead, the same relationship `SecureRandomIdentity` already has
    # to `SequentialIdentity`.
    #
    # **This file owns transport only** — spawning the process, unwrapping
    # the CLI's own JSON envelope (`{"result": "..."}`) down to the
    # model's raw text, and parsing that text as JSON. It hands back a
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
                      "before or after it, no markdown code fence. ".freeze

      module_function

      # Asks the model for the next best interview question, as a raw parsed-JSON reply.
      #
      # **The next best question**. `state` is whatever
      # `Interview::Session#declaration`/`#gaps` produced — passed
      # through as JSON, not reformatted, so this adapter never
      # re-derives what the session already knows.
      #
      # @param state [Hash] the interview's whole current picture (declaration plus gaps),
      #   JSON-able
      # @param asked [Array<Object>] JSON-able record of the questions already asked
      # @return [Object] the parsed JSON reply, expected to be a Hash holding a `"questions"`
      #   array; shape validated downstream by `Ports::Agent::Answers.questions`
      # @raise [Ports::Agent::Unavailable] if the `claude` binary is missing, the subprocess
      #   fails, or the call times out
      # @raise [Ports::Agent::ValidationError] if the CLI's own envelope has no `"result"`, or
      #   the result text is not valid JSON
      def ask(state:, asked:)
        call(
          system:  SYSTEM_PREFIX + "Given the domain model so far, ask the single best next " \
                                   'discovery question. Reply as {"questions": [{"text": "...", "because": "..."}]} ' \
                                   "with exactly one entry. Never repeat a question already asked.",
          payload: { state: state, already_asked: asked }
        )
      end

      # Turns a human's sentence into proposed declarations, as a raw parsed-JSON reply.
      #
      # Prose -> proposed declarations.
      #
      # @param prose [String] a human's plain-English sentence
      # @param state [Hash] the interview's whole current picture, JSON-able
      # @return [Object] the parsed JSON reply, expected to be a Hash holding a `"proposals"`
      #   array; shape validated downstream by `Ports::Agent::Answers.proposals`
      # @raise [Ports::Agent::Unavailable] if the `claude` binary is missing, the subprocess
      #   fails, or the call times out
      # @raise [Ports::Agent::ValidationError] if the CLI's own envelope has no `"result"`, or
      #   the result text is not valid JSON
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

      # Asks the model to judge a declared model on taste, as a raw parsed-JSON reply.
      #
      # What is wrong with this as a model — closed to the same kind
      # vocabulary `Ports::Agent::CRITIQUE_KINDS` declares, spelled out
      # here too since the system prompt is the only place the model
      # itself ever sees that list.
      #
      # @param declared [Hash] the chapter as declared so far, JSON-able
      # @param refusals [Array<Object>] JSON-able refusals the language itself already raised
      # @param findings [Array<Object>] JSON-able mechanical findings already found
      # @return [Object] the parsed JSON reply, expected to be a Hash holding a `"findings"`
      #   array; shape validated downstream by `Ports::Agent::Answers.findings`
      # @raise [Ports::Agent::Unavailable] if the `claude` binary is missing, the subprocess
      #   fails, or the call times out
      # @raise [Ports::Agent::ValidationError] if the CLI's own envelope has no `"result"`, or
      #   the result text is not valid JSON
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

      # Suggests a name for a construct, as a raw parsed-JSON reply.
      #
      # **Vocabulary help**. Named `suggest_name`, not `name` — see
      # `Ports::Agent#suggest_name`'s own comment for why `name` is
      # never a safe module-function name here.
      #
      # @param meaning [String] what the new name needs to mean
      # @param kind [String] the kind of construct being named, such as `"event"`
      # @param near [Array<String>] names already in use nearby, which a suggestion must not
      #   collide with
      # @return [Object] the parsed JSON reply, expected to be a Hash holding a `"names"`
      #   array; shape validated downstream by `Ports::Agent::Answers.suggestions`
      # @raise [Ports::Agent::Unavailable] if the `claude` binary is missing, the subprocess
      #   fails, or the call times out
      # @raise [Ports::Agent::ValidationError] if the CLI's own envelope has no `"result"`, or
      #   the result text is not valid JSON
      def suggest_name(meaning:, kind:, near:)
        call(
          system:  SYSTEM_PREFIX + "Suggest a name for a #{kind} meaning \"#{meaning}\", distinct from " \
                                   'the names already in use nearby. Reply as {"names": [{"name": "...", "because": ' \
                                   '"...", "rejected": ["...", "..."]}]} with exactly one entry.',
          payload: { meaning: meaning, kind: kind, near: near }
        )
      end

      # ── transport ───────────────────────────────────────────────────

      # Runs `claude` as a subprocess with `payload` on stdin and returns its parsed JSON reply.
      #
      # @param system [String] the system-prompt text appended via `--append-system-prompt`
      # @param payload [Hash] the JSON-able payload written to the subprocess's stdin
      # @return [Object] the parsed JSON value nested under the CLI envelope's `"result"` key
      #   (see `unwrap`)
      # @raise [Ports::Agent::Unavailable] if the `claude` binary is missing, the subprocess
      #   exits non-zero, or the call does not finish within `TIMEOUT_SECONDS`
      # @raise [Ports::Agent::ValidationError] if the envelope has no `"result"`, or the
      #   result text is not valid JSON (see `unwrap`)
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

      # Unwraps the CLI's own JSON envelope down to the model's parsed reply.
      #
      # @param stdout [String] the raw stdout of the `claude` CLI invocation, the outer
      #   `{"result": "..."}` envelope
      # @return [Object] the JSON value parsed out of the envelope's `"result"` string
      # @raise [Ports::Agent::ValidationError] if the envelope has no `"result"` key, or
      #   `result` is not valid JSON
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
