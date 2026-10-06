require "optparse"
require_relative "suite"
require_relative "report"

module Hecks
  module Bench
    # The command line behind `hecks bench`: parses flags, runs the `Suite`, prints the report.
    # Lives in `lib/` so a spec can drive it without shelling out.
    module CLI
      # The defaults `hecks bench` runs with when no flag says otherwise.
      DEFAULTS = { domains: %w[pizzas banking], targets: Suite::TARGETS, warmup: 200, iterations: 1000,
                   runs: 3 }.freeze

      # Each flag: which hash its value lands in (`:values` for the configuration, `:extras` for
      # the output choices), the key it sets, and its `OptionParser` arguments.
      FLAGS = [
        [:values, :domains, ["--domain NAMES", Array, "pizzas, banking (default: both)"]],
        [:values, :targets, ["--targets NAMES", Array, "#{Suite::TARGETS.join(", ")} (default: all)"]],
        [:values, :iterations, ["--iterations N", Integer, "timed cycles per run (default #{DEFAULTS[:iterations]})"]],
        [:values, :warmup, ["--warmup N", Integer, "discarded cycles before timing (default #{DEFAULTS[:warmup]})"]],
        [:values, :runs, ["--runs N", Integer, "fresh boots per target, median reported (default #{DEFAULTS[:runs]})"]],
        [:extras, :rust_binary, ["--rust-binary PATH", "use this `rust` binary instead of building one"]],
        [:extras, :format, ["--format FORMAT", %w[markdown json], "markdown (default) or json"]],
        [:extras, :output, ["--output PATH", "also write the full JSON result here"]]
      ].freeze

      module_function

      # Runs the benchmark described by `argv` and prints its report.
      #
      # @return [Integer] the process exit status: 0 on success, 2 for a usage error
      def run(argv, out: $stdout, err: $stderr)
        options = parse(argv)
        result = Suite.call(options.fetch(:config), log: err)
        out.puts(options[:format] == "json" ? Report.json(result) : Report.markdown(result))
        File.write(options[:output], Report.json(result)) if options[:output]
        0
      rescue OptionParser::ParseError, ArgumentError => e
        err.puts "hecks bench: #{e.message}"
        2
      end

      # Turns command-line arguments into a configuration and output choices.
      #
      # @raise [OptionParser::ParseError] on an unknown or malformed flag
      def parse(argv)
        values = DEFAULTS.dup
        extras = { format: "markdown", output: nil, rust_binary: nil }
        parser(values, extras).parse(argv.dup)
        { config: Suite::Config.new(**values, rust_binary: extras[:rust_binary]),
          format: extras[:format], output: extras[:output] }
      end

      def parser(values, extras)
        OptionParser.new do |opts|
          opts.banner = "usage: hecks bench [options]"
          FLAGS.each do |store, key, spec|
            target = store == :values ? values : extras
            opts.on(*spec) { |v| target[key] = v }
          end
        end
      end
    end
  end
end
