require "json"
require_relative "../../hecks"
# ADR 0033 — a domain wired to PostgresEra needs this plugin loaded
# explicitly; the era/lineage subsystem does not load with core.
require_relative "../ports/persistence/plugins/era"
require_relative "run_expectations"

module Hecks
  module CLI
    # The command behind `hecks run`: dispatches one verb from the
    # command line, or executes a JSON step list and reports instances, events,
    # refusals, reactions, sagas and query rows.
    #
    # `run bug.discover reference=BUG#1 severity=high …` needs no JSON; the verb
    # tree and its arguments are projected from the bluebook, so this knows nothing
    # about any domain and its help cannot go stale. The step-list form takes a
    # script path, `-` for stdin, or the JSON itself. The first argument is a
    # domain only when it is a directory; otherwise the nearest enclosing one is
    # used.
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
        domain = resolve_domain(argv, usage)

        # The command-line form answers unless the first argument is script-shaped,
        # in which case the step-list form takes over.
        cli_form(domain, argv, program) unless argv.first && script_shaped?(argv.first)

        run_script(domain, argv, usage)
      end

      # @api private
      def resolve_domain(argv, usage)
        here = Adapters::Folder.new.domain_root
        domain = argv.first && File.directory?(argv.first) ? argv.shift : here
        abort "no bluebook here — #{Dir.pwd} is not inside a domain. #{usage}" unless domain

        domain
      end

      # @api private
      def run_script(domain, argv, usage)
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

      # No fall-through: reached only when the argument is not script-shaped, so a
      # near miss deserves the runner's "did you mean" rather than the step-list
      # form's "no such script".
      def cli_form(domain, argv, program)
        runtime = Hecks.boot(domain, install_doors: false)
        text, status = Doors::CliRunner.call(runtime: runtime, argv: argv, program: program)
        status.zero? ? puts(text) : abort(text)
        exit 0
      end

      def script_shaped?(arg) = arg == "-" || arg.match?(/\A\s*\{/) || File.file?(arg)

      # Decided by looking, because a script beginning with `{` is not a filename
      # anybody meant.
      def read_source(script)
        case script
        when "-" then $stdin.read
        when /\A\s*\{/ then script
        else
          File.exist?(script) ? File.read(script) : abort("no such script: #{script}")
        end
      end

      # Parsed before anything boots, because booting opens a real store and a typo
      # in the JSON should cost a sentence, not a connection.
      def parse(source)
        JSON.parse(source)
      rescue JSON::ParserError => e
        abort "that is not JSON: #{e.message.lines.first.strip}"
      end

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

        dispatch_verb(runtime, step["verb"], args, refusals)
      end

      # @api private
      def dispatch_verb(runtime, verb, args, refusals)
        runtime.dispatch_flat(verb, args)
      rescue StandardError => e
        refusals << { verb: verb, error: e.message.to_s }
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

      # @api private
      def unmet_expectations(expectations, report) = RunExpectations.unmet(expectations, report)
    end
  end
end
