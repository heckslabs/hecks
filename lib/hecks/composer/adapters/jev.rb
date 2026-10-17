require "json"
require "open3"
require "tmpdir"

require_relative "../agent"

module Hecks
  module Adapters
    # `composer_agent` fulfillment for `classify` alone: the `jev` categorizer, which answers a
    # multiple-choice question about a piece of text. It carries no key of its own; the script
    # reads one from the environment or from 1Password, so nothing secret is written here.
    #
    # `draft` and `wire` are not this adapter's work.
    module Jev
      QUESTIONS = {
        "intent" => {
          "type"         => "choice",
          "instructions" => "What is the author of a domain bluebook asking an editor to do?",
          "criteria"     => {
            "edit"       => "change what the domain declares: an aggregate, command, attribute, rule or lifecycle",
            "wire"       => "change how the domain is wired to the outside: persistence, adapters, ports, deployment",
            "question"   => "explain or answer something about the domain, changing nothing",
            "new_domain" => "start a new domain from a description of a business"
          }
        }
      }.freeze

      module_function

      # @param prompt [String] what the author typed
      # @return [Hash] `"intent"` one of {Composer::Agent::INTENTS}
      # @raise [Composer::Agent::Unavailable] if `jev` is missing, fails or answers nothing
      def classify(prompt:)
        answers = ask(prompt)
        { "intent" => choice(answers["intent"]) }
      end

      # @api private
      def ask(prompt)
        Dir.mktmpdir("hecks-jev") { |dir| JSON.parse(run(prompt, File.join(dir, "questions.json"))) }
      rescue Errno::ENOENT => e
        raise Composer::Agent::Unavailable, "jev is not on PATH: #{e.message}"
      rescue JSON::ParserError => e
        raise Composer::Agent::Unavailable, "jev's answer was not JSON: #{e.message}"
      end

      # Runs `jev` on the prompt, with the questions written to `path` beside it.
      # @api private
      def run(prompt, path)
        File.write(path, JSON.generate(QUESTIONS))
        out, err, status = Open3.capture3(ENV.fetch("HECKS_JEV", "jev"), path, "-", stdin_data: prompt)
        return out if status.success?

        raise Composer::Agent::Unavailable, "jev exited #{status.exitstatus}: #{err.lines.first}"
      end

      # `jev` names a choice by its key; accept the bare key or a row that carries it.
      # @api private
      def choice(answer)
        return answer unless answer.is_a?(Hash)

        answer.values_at("choice", "answer", "value", "label").compact.first
      end
    end
  end
end
