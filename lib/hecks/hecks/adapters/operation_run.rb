# frozen_string_literal: true

require "json"
require "hecks"
# ADR 0033: a domain wired to PostgresEra needs this plugin loaded explicitly; the era/lineage
# subsystem does not load with core.
require "hecks/ports/persistence/plugins/era"
require "hecks/runtime/step_run"
require_relative "console_capture"

module Hecks
  module Adapters
    # Dispatches one verb against a domain, or executes a JSON step list and reports what
    # `StepRun` found, for `Operation.run!` and the Catcher's requests.
    #
    # A verb needs no JSON: the verb tree and its arguments are projected from the bluebook, so
    # this knows nothing about any domain. The step-list form takes a script path, `-` for the
    # given input, or the JSON itself. The first word is a domain only when it is a directory;
    # otherwise the nearest enclosing one is used.
    module OperationRun
      # Script text given inline: a JSON object, perhaps after some spaces.
      INLINE_SCRIPT = /\A\s*\{/

      # What a run answered, and a notice for the operator (an environment the domain has no
      # overlay for), or nil.
      Result = Struct.new(:text, :notice)

      module_function

      # @param words [Array<String>] an optional domain directory, then a verb with `name=value`
      #   pairs, a script path, `-`, or inline JSON
      # @param program [String] the name usage and help messages call this command by
      # @param input [IO] read for a script given as `-`
      # @param environment [String, nil] the environment the run was started under
      # @return [Result] the verb's answer or the step list's JSON report, and any notice
      # @raise [ConsoleCapture::Failure] on a refusal, a usage error or an unmet expectation
      def call(words, program:, input:, environment: nil)
        words = words.dup
        domain = resolve_domain(words, usage(program))
        notice = unmatched_environment(domain, environment)
        return Result.new(cli_form(domain, words, program), notice) unless words.first && script_shaped?(words.first)

        Result.new(run_script(domain, words.first, usage(program), input), notice)
      end

      # Runs as `hecks run` in this process, with the process's input and environment, and says
      # any notice on stderr, apart from the answer.
      #
      # @param words [Array<String>] as `call` takes them
      # @return [String] the run's answer
      # @raise [ConsoleCapture::Failure] as `call` does
      def run_noticed(words)
        result = call(words, program: "hecks run", input: $stdin, environment: ENV.fetch("HECKS_ENVIRONMENT", nil))
        warn result.notice if result.notice
        result.text
      end

      # @param program [String] the name this command is called by
      # @return [String] how to call it
      def usage(program) = "usage: #{program} [domain] <verb [name=value …] | script.json | - | '{\"steps\":[…]}'>"

      # @api private
      def resolve_domain(words, usage)
        domain = words.first && File.directory?(words.first) ? words.shift : Folder.new.domain_root
        raise ConsoleCapture::Failure, "no bluebook here — #{Dir.pwd} is not inside a domain. #{usage}" unless domain

        domain
      end

      # A run saves what it dispatches through whatever the domain binds. An environment only
      # changes that for a domain with an `environments/<name>.*` overlay; for any other the boot
      # ignores it, so a run would persist for real without a word.
      #
      # @param domain [String] the domain directory
      # @param environment [String, nil] the environment named
      # @return [String, nil] the notice, when the domain has no overlay for the environment
      def unmatched_environment(domain, environment)
        name = environment.to_s.strip
        return if name.empty?

        overlays = File.join(Folder.new.bluebook_directory(domain), "environments", "#{name}.*")
        return unless Dir[overlays].empty?

        "[hecks] HECKS_ENVIRONMENT=#{name} has no overlay in #{File.dirname(overlays)}, " \
          "so this run saves through the domain's own bindings"
      end

      # The run is reported before it is judged: an expectation that fails says what was wanted
      # and never what happened, so the refusal carries the report first.
      #
      # @api private
      def run_script(domain, script, usage, input)
        document = parse(read_source(script, input))
        steps = document["steps"] or raise ConsoleCapture::Failure, %(the script has no "steps" — #{usage})
        report = StepRun.execute(Hecks.boot(domain), steps)
        text = JSON.pretty_generate(report)
        unmet = StepRun.unmet(document["expectations"] || {}, report)
        raise ConsoleCapture::Failure, ([text] + unmet).join("\n") unless unmet.empty?

        text
      end

      # A verb always writes, so its word carries the bang the launcher requires.
      #
      # @api private
      def writing(words)
        return words if words.empty? || words.first.end_with?("!")

        ["#{words.first}!", *words.drop(1)]
      end

      # A verb run boots without the Ruby facade, so it binds it for a domain that declares ports.
      #
      # @api private
      def cli_form(domain, words, program)
        runtime = Hecks.boot(domain, install_driving: false)
        Assembly.bind_ported_runtime(runtime)
        text, status = Driving::CliRunner.call(runtime: runtime, argv: writing(words), program: program)
        raise ConsoleCapture::Failure, text unless status.zero?

        text
      end

      # @api private
      def script_shaped?(word) = word == "-" || word.match?(INLINE_SCRIPT) || File.file?(word)

      # Decided by looking, because a script beginning with `{` is not a filename anybody meant.
      #
      # @api private
      def read_source(script, input)
        return input.read if script == "-"
        return script if script.match?(INLINE_SCRIPT)
        raise ConsoleCapture::Failure, "no such script: #{script}" unless File.exist?(script)

        File.read(script)
      end

      # Parsed before anything boots, because booting opens a real store and a typo in the JSON
      # should cost a sentence, not a connection.
      #
      # @api private
      def parse(source)
        JSON.parse(source)
      rescue JSON::ParserError => e
        raise ConsoleCapture::Failure, "that is not JSON: #{Text.first_line(e.message)}"
      end
    end
  end
end
