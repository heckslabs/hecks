require "optparse"

module Hecks
  module Bench
    # The command line behind `bin/bench`: parses flags, runs the `Suite`, prints the report.
    #
    # Kept in `lib/` so a spec can drive it with a tiny configuration and read what it
    # prints, rather than shelling out to a script.
    module CLI
      # The defaults `bin/bench` runs with when no flag says otherwise.
      DEFAULTS = { domains: %w[pizzas banking], targets: Suite::TARGETS, warmup: 200, iterations: 1000,
                   runs: 3 }.freeze

      module_function

      # Runs the benchmark described by the command line and prints its report.
      #
      # @param argv [Array<String>] the command-line arguments
      # @param out [#puts] where the report goes
      # @param err [#puts] where progress and usage errors go
      # @return [Integer] the process exit status: 0 on success, 2 for a usage error
      def run(argv, out: $stdout, err: $stderr)
        options = parse(argv)
        result = Suite.call(options.fetch(:config), log: err)
        out.puts(options[:format] == "json" ? Report.json(result) : Report.markdown(result))
        File.write(options[:output], Report.json(result)) if options[:output]
        0
      rescue OptionParser::ParseError, ArgumentError => e
        err.puts "bin/bench: #{e.message}"
        2
      end

      # Turns command-line arguments into a configuration and output choices.
      #
      # @param argv [Array<String>] the command-line arguments
      # @return [Hash{Symbol => Object}] `:config` (a `Suite::Config`), `:format` and `:output`
      # @raise [OptionParser::ParseError] on an unknown or malformed flag
      def parse(argv)
        values = DEFAULTS.dup
        extras = { format: "markdown", output: nil, rust_binary: nil }
        parser(values, extras).parse(argv.dup)
        { config: Suite::Config.new(**values, rust_binary: extras[:rust_binary]),
          format: extras[:format], output: extras[:output] }
      end

      # Builds the flag parser.
      #
      # @param values [Hash{Symbol => Object}] the `Suite::Config` fields, filled in as flags parse
      # @param extras [Hash{Symbol => Object}] the output choices, filled in as flags parse
      # @return [OptionParser] the parser
      def parser(values, extras)
        OptionParser.new do |opts|
          opts.banner = "usage: bin/bench [options]"
          opts.on("--domain NAMES", Array, "pizzas, banking (default: both)") { |v| values[:domains] = v }
          opts.on("--targets NAMES", Array, "#{Suite::TARGETS.join(', ')} (default: all)") { |v| values[:targets] = v }
          opts.on("--iterations N", Integer, "timed cycles per run (default #{DEFAULTS[:iterations]})") do |v|
            values[:iterations] = v
          end
          opts.on("--warmup N", Integer, "discarded cycles before timing (default #{DEFAULTS[:warmup]})") do |v|
            values[:warmup] = v
          end
          opts.on("--runs N", Integer, "fresh boots per target, median reported (default #{DEFAULTS[:runs]})") do |v|
            values[:runs] = v
          end
          opts.on("--rust-binary PATH", "use this `rust` binary instead of building one") { |v| extras[:rust_binary] = v }
          opts.on("--format FORMAT", %w[markdown json], "markdown (default) or json") { |v| extras[:format] = v }
          opts.on("--output PATH", "also write the full JSON result here") { |v| extras[:output] = v }
        end
      end
    end
  end
end
