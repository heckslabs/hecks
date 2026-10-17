# frozen_string_literal: true

require_relative "../../../hecks"
require_relative "qa_round_trip/bench"
require_relative "qa_round_trip/scoring"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control query target.round_trip`: a recovery benchmark.
    #
    #   prepare --seed 46 --out bench [--forms a,b] [--scripts 40] [--steps 60] [--adversarial 0.2]
    #   score --bench bench --program "node main.js"
    #   score --bench bench --domain recovered [--verb-map Wharf.Slot.Label=Wharf.LabelSlot]
    #
    # `prepare` writes a benchmark of a domain nobody wrote (`Bench`). An implementer builds
    # `spec.bluebook` without Hecks; an analyst who sees only that program recovers a domain;
    # `score` measures either against Hecks's own answers.
    #
    # Exit codes: 0 prepared, or every script agreed and a domain lacks none of the key's
    # declarations; 1 a script disagreed or a declaration is missing; 2 a usage error.
    class QaRoundTrip
      EXIT_AGREED = 0
      EXIT_DISAGREED = 1
      EXIT_USAGE = 2

      USAGE = <<~TEXT
        usage: hecks quality_control round_trip prepare --seed N --out DIR [--forms a,b] [--scripts N] [--steps N] [--adversarial F]
               hecks quality_control round_trip score --bench DIR (--program "CMD" | --domain DIR [--verb-map A.B=A.C,...])
      TEXT

      # Reads `--verb-map`'s `Aggregate.Command=Aggregate.Other,...` into protocol command pairs.
      VERB_MAP = ->(text) { text.split(",").to_h { |pair| pair.split("=", 2) } }

      # Each flag that takes a value: the option it sets and how the value is read.
      FLAGS = {
        "--seed" => [:seed, ->(v) { Integer(v) }], "--out" => [:out, :itself.to_proc],
        "--forms" => [:forms, ->(v) { v.split(",") }], "--scripts" => [:scripts, ->(v) { Integer(v) }],
        "--steps" => [:steps, ->(v) { Integer(v) }], "--adversarial" => [:adversarial, ->(v) { Float(v) }],
        "--bench" => [:bench, :itself.to_proc], "--program" => [:program, :itself.to_proc],
        "--domain" => [:domain, :itself.to_proc], "--verb-map" => [:verb_map, VERB_MAP]
      }.freeze

      # Runs one subcommand.
      #
      # @param argv [Array<String>] the subcommand, then its flags
      # @param root [String] the repository root
      # @param out [IO] where the report goes
      # @return [Integer] the exit status
      def self.call(argv, root:, out: $stdout)
        new(out: out).call(argv)
      end

      # @param out [IO] where the report goes
      def initialize(out: $stdout)
        @out = out
      end

      # @param argv [Array<String>] the subcommand, then its flags
      # @return [Integer] the exit status
      def call(argv)
        subcommand, *rest = argv
        options = parse(rest)
        case subcommand
        when "prepare" then prepare(options)
        when "score" then score(options)
        else usage
        end
      rescue ArgumentError, KeyError => e
        usage(e.message)
      end

      private

      def prepare(options)
        battery = { scripts: options.fetch(:scripts, 40), steps: options.fetch(:steps, 60),
                    adversarial: options.fetch(:adversarial, 0.2) }
        count = Bench.new(options.fetch(:out)).prepare(seed: options.fetch(:seed), forms: options[:forms], battery: battery)
        @out.puts "prepared #{options[:out]}: #{count} scripts; give the implementer spec.bluebook, PROTOCOL.md " \
                  "and prompts/implementer.md, and keep key/ and battery/ from the analyst"
        @out.puts Bench.new(options[:out]).coverage_report
        EXIT_AGREED
      end

      def score(options)
        scoring = Scoring.new(Bench.new(options.fetch(:bench)))
        agreed, report = if options[:program] then scoring.program(options[:program])
                         else scoring.domain(options.fetch(:domain), verb_map: options.fetch(:verb_map, {}))
                         end
        @out.puts report
        agreed ? EXIT_AGREED : EXIT_DISAGREED
      end

      def parse(argv)
        argv.each_slice(2).to_h do |flag, value|
          name, read = FLAGS.fetch(flag) { raise ArgumentError, "unknown flag #{flag}" }
          raise ArgumentError, "#{flag} needs a value" if value.nil?

          [name, read.call(value)]
        end
      end

      def usage(message = nil)
        @out.puts message if message
        @out.puts USAGE
        EXIT_USAGE
      end
    end
  end
end
