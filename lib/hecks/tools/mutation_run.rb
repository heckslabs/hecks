# frozen_string_literal: true

require_relative "../tools"

module Hecks
  module Tools
    # Mutation-tests a domain's own checks: changes its bluebooks in small ways and reports every
    # change that the fuzz properties, the corpus script and the domain's behaviors tests let through.
    #
    #   hecks mutate <domain> [--seed N] [--budget N] [--seeds N] [--steps N] [--corpus PATH]
    #                         [--operators a,b] [--min-score FRACTION]
    #
    # Exit 0 unless `--min-score` is given and the score is below it. See `Hecks::Fuzzing::Mutation`.
    module MutationRun
      USAGE = "usage: hecks mutate <domain> [--seed N] [--budget N] [--seeds N] [--steps N] [--corpus PATH] " \
              "[--operators a,b] [--min-score FRACTION]"

      # Each flag: the option it sets and how its value is read.
      FLAGS = {
        "--seed"      => [:seed, :integer],
        "--budget"    => [:budget, :integer],
        "--seeds"     => [:seeds, :integer],
        "--steps"     => [:steps, :integer],
        "--corpus"    => [:corpus, :text],
        "--operators" => [:operators, :names],
        "--min-score" => [:min_score, :fraction]
      }.freeze

      READERS = {
        integer:  ->(text) { Integer(text) },
        fraction: ->(text) { Float(text) },
        text:     ->(text) { text },
        names:    ->(text) { text.to_s.split(",").map(&:to_sym) }
      }.freeze

      module_function

      # @param argv [Array<String>] the domain directory, then the flags
      # @param root [String] the checkout (unused: the domain is named by path)
      # @return [Integer] 0 when the score is high enough or no minimum was asked, 1 when it is not
      # @raise [SystemExit] with the usage line when an argument is missing or unknown
      def main(argv, root: Tools::ROOT)
        _ = root
        require "hecks"
        require "hecks/fuzzing/mutation"
        args = argv.dup
        domain = args.shift or abort USAGE
        options = parse(args)

        report = Hecks::Fuzzing::Mutation::Run.call(domain, **options.except(:min_score))
        puts report
        report.passes?(options.fetch(:min_score, 0.0)) ? 0 : 1
      end

      # @param args [Array<String>] the flags, consumed
      # @return [Hash] the options the flags set
      def parse(args)
        options = {}
        apply_flag(options, args.shift, args) until args.empty?
        options
      end

      # Records one flag in `options`, taking its value from `rest`.
      def apply_flag(options, flag, rest)
        key, kind = FLAGS.fetch(flag) { abort "unknown argument #{flag.inspect}\n#{USAGE}" }
        options[key] = READERS.fetch(kind).call(rest.shift)
      rescue ArgumentError, TypeError
        abort "#{flag} needs a #{kind == :fraction ? "number" : "value"}\n#{USAGE}"
      end
    end
  end
end
