require "json"
require_relative "../../hecks"
# ADR 0033 — a domain wired to PostgresEra needs this plugin loaded
# explicitly; the era/lineage subsystem does not load with core.
require_relative "../ports/persistence/plugins/era"

module Hecks
  module CLI
    # The command behind `bin/run` and `hecks run`: dispatches one verb from the
    # command line, or executes a JSON step list and reports instances, events,
    # refusals, reactions, sagas and query rows.
    #
    # ## Two forms, one argument
    #
    # `run bug.discover reference=BUG#1 severity=high …` needs no JSON. The verb
    # tree, every argument, its declared type and every way the verb can refuse are
    # projected out of the bluebook (`Projector::CliProjector`) and run by
    # `Facade::CliRunner`, so this knows nothing about any domain and its help
    # cannot go stale. The step-list form takes a script path, `-` for stdin, or the
    # JSON itself, which is how the corpus scripts under `spec/corpus/` are run.
    #
    # ## Standing in a domain is enough
    #
    # `Adapters::Folder#domain_root` walks up for the nearest `.hecksagon`, so inside
    # a domain the path can be left off. The first argument is a domain only when it
    # is a directory.
    module Run
      module_function

      # Runs `argv` as a verb invocation or a step list against a domain.
      #
      # @param argv [Array<String>] the arguments: an optional domain directory, then
      #   a verb with `name=value` pairs, a script path, `-`, or inline JSON
      # @param program [String] the name usage and help messages call this command by
      # @return [void]
      # @raise [SystemExit] on any refusal, usage error or unmet expectation, and
      #   after the command-line form answers
      def call(argv, program:)
        usage = "usage: #{program} [domain] <verb [name=value …] | script.json | - | '{\"steps\":[…]}'>"
        argv = argv.dup
        here = Adapters::Folder.new.domain_root
        domain = argv.first && File.directory?(argv.first) ? argv.shift : here
        abort "no bluebook here — #{Dir.pwd} is not inside a domain. #{usage}" unless domain

        # The command-line form answers unless the first argument is script-shaped,
        # in which case the step-list form takes over.
        cli_form(domain, argv, program) unless argv.first && script_shaped?(argv.first)

        script = argv.first or abort usage
        document = parse(read_source(script))
        steps = document["steps"] or abort %(the script has no "steps" — #{usage})
        report = execute(Hecks.boot(domain), steps)

        # The run is reported before it is judged: an expectation that fails says
        # what was wanted and never what happened, so the evidence goes to stdout
        # first and every unmet expectation is collected rather than aborted on.
        puts JSON.pretty_generate(report)
        unmet = unmet_expectations(document["expectations"] || {}, report)
        abort unmet.join("\n") unless unmet.empty?
      end

      # Boots `domain` and dispatches `argv` as a projected verb invocation, printing
      # the result and exiting the process.
      #
      # **No fall-through**. This is reached only when the argument is not
      # script-shaped, so a near miss deserves the runner's "did you mean" rather
      # than the step-list form's "no such script".
      #
      # @param domain [String] the domain's directory path
      # @param argv [Array<String>] the arguments after the domain, e.g.
      #   `["bug.discover", "reference=BUG#1"]`
      # @param program [String] the name the runner's help calls this command by
      # @return [void]
      # @raise [SystemExit] always
      def cli_form(domain, argv, program)
        runtime = Hecks.boot(domain, install_facade: false)
        text, status = Facade::CliRunner.call(runtime: runtime, argv: argv, program: program)
        status.zero? ? puts(text) : abort(text)
        exit 0
      end

      # Says whether `arg` is a step list rather than a verb: stdin, inline JSON, or
      # a file that exists.
      #
      # @param arg [String] the first argument after the domain
      # @return [Boolean] true when `arg` is script-shaped
      def script_shaped?(arg) = arg == "-" || arg.match?(/\A\s*\{/) || File.file?(arg)

      # Reads the step list from stdin, from the argument itself, or from a file,
      # decided by looking, because a script beginning with `{` is not a filename
      # anybody meant.
      #
      # @param script [String] `-`, inline JSON, or a file path
      # @return [String] the script's JSON text
      # @raise [SystemExit] when `script` names no file
      def read_source(script)
        case script
        when "-" then $stdin.read
        when /\A\s*\{/ then script
        else
          File.exist?(script) ? File.read(script) : abort("no such script: #{script}")
        end
      end

      # Parses the step list before anything boots, because booting opens a real
      # store and a typo in the JSON should cost a sentence, not a connection.
      #
      # @param source [String] the script's JSON text
      # @return [Hash{String => Object}] the parsed script
      # @raise [SystemExit] when `source` is not JSON
      def parse(source)
        JSON.parse(source)
      rescue JSON::ParserError => e
        abort "that is not JSON: #{e.message.lines.first.strip}"
      end

      # Runs every step and gathers what the runtime holds afterwards.
      #
      # @param runtime [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted domain
      # @param steps [Array<Hash{String => Object}>] the script's steps, each a
      #   `"verb"` or a `"query"` with optional `"args"`
      # @return [Hash{Symbol => Object}] `:instances`, `:events`, `:refusals`,
      #   `:reactions`, `:sagas` and `:queries`, in the order they are printed
      def execute(runtime, steps)
        refusals = []
        queries = []
        steps.each { |step| run_step(runtime, step, refusals, queries) }

        { instances: instances(runtime), events: events(runtime), refusals: refusals,
          reactions: runtime.reactions, sagas: runtime.sagas, queries: queries }
      end

      # @api private
      def run_step(runtime, step, refusals, queries)
        args = (step["args"] || {}).transform_keys(&:to_sym)
        if (question = step["query"])
          queries << ask(runtime, question, args)
          return
        end

        verb = step["verb"]
        begin
          runtime.dispatch_flat(verb, args)
        rescue StandardError => e
          refusals << { verb: verb, error: e.message.to_s }
        end
      end

      # @api private
      def ask(runtime, question, args)
        { query: question, args: args, rows: runtime.query(question, **args) }
      rescue StandardError => e
        { query: question, args: args, error: e.message }
      end

      # @api private
      def instances(runtime)
        runtime.registry.bluebooks.each_with_object({}) do |(domain_name, bluebook), all|
          bluebook.aggregates.each do |aggregate|
            runtime.registry.repository(domain_name, aggregate).all.each do |record|
              all["#{domain_name}::#{aggregate.name}##{record.id}"] = record.state
            end
          end
        end
      end

      # @api private
      def events(runtime)
        runtime.events.map do |event|
          { name: event.name, aggregate: event.aggregate, id: event.id, payload: event.payload }
        end
      end

      # Checks the script's `"expectations"` against what the run produced.
      #
      # @param expectations [Hash{String => Object}] the script's `"event_names"`,
      #   `"refusals"` and `"instances"` expectations; `{}` when it declares none
      # @param report [Hash{Symbol => Object}] what `execute` answered
      # @return [Array<String>] one message per unmet expectation; empty when every
      #   one held
      def unmet_expectations(expectations, report)
        missing_events = Array(expectations["event_names"]) - report[:events].map { |event| event[:name] }
        unmet = []
        unmet << "matrix expected events missing: #{missing_events.join(', ')}" unless missing_events.empty?
        unmet.concat(unmet_refusals(Array(expectations["refusals"]), report[:refusals]))
        unmet.concat(unmet_instances(expectations["instances"] || {}, report[:instances]))
      end

      # @api private
      def unmet_refusals(expected_refusals, refusals)
        expected_refusals.filter_map do |expected|
          verb = expected.fetch("verb")
          matched = refusals.any? do |refusal|
            refusal[:verb] == verb && refusal[:error].include?(expected.fetch("includes"))
          end
          next if matched

          # A refusal that changed its words is a different story from one that never
          # happened, so the actual errors are printed beside the wanted one.
          said = refusals.select { |refusal| refusal[:verb] == verb }.map { |refusal| refusal[:error] }.uniq
          "matrix expected refusal missing: #{expected}\n  " \
            "#{verb} actually refused with: #{said.empty? ? '(nothing — every attempt was accepted)' : said.inspect}"
        end
      end

      # @api private
      def unmet_instances(expected_instances, instances)
        expected_instances.flat_map do |key, fields|
          actual = instances[key] || {}
          fields.filter_map do |field, value|
            next if actual[field.to_sym] == value

            "matrix expected #{key}.#{field}=#{value.inspect}, got #{actual[field.to_sym].inspect}"
          end
        end
      end
    end
  end
end
