# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "../../../hecks"
require "hecks/rust_build"
require_relative "../../fuzzing"
require_relative "../../fuzzing/domain_generator"
require_relative "../../fuzzing/generated_domain_check"
require_relative "child"
require_relative "qa_generated_domains/arguments"
require_relative "qa_generated_domains/promotion"
require_relative "qa_generated_domains/evaluation"
require_relative "qa_generated_domains/shrinking"
require_relative "qa_generated_domains/reporting"
require_relative "qa_generated_domains/blueprints"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control target.check_generated_domains`: generates domains
    # nobody wrote and checks them the way the rotation does (`USAGE` lists the forms: generate,
    # `--blueprint`, `--source` and `--promote`).
    #
    # Exit codes: 0 every valid domain clean; 2 at least one finding; 1 operational error.
    #
    # Every generated domain is named `QaGenerated`, so each is checked in its own child process
    # (`--check <dir>`, prints one `QA_GENERATED_RESULT <json>` line). Findings are shrunk twice:
    # the domain, then the steps. `--rust` builds a scratch crate under `tmp/qa-generated/rust`.
    # `--source` adopts a bluebook written elsewhere; a `HYPOTHESIS.md` beside it rides into
    # `NOTES.md`. It never touches the QA ledger; a domain that does not boot is `invalid`, never a
    # finding.
    class QaGeneratedDomains
      include Arguments
      include Promotion
      include Evaluation
      include Shrinking
      include Reporting
      include Blueprints

      EXIT_OK = 0
      EXIT_ERROR = 1
      EXIT_FOUND = 2
      RESULT_MARKER = "QA_GENERATED_RESULT "

      USAGE = "usage: hecks quality_control check_generated_domains [--domains N] [--start SEED] " \
              "[--forms a,b] [--seeds K] [--steps M] [--adversarial F] [--rust] [--shrink-budget B] " \
              "[--domain-shrink-budget D]\n       " \
              "hecks quality_control check_generated_domains --source <file.bluebook> [--source …] [--rust] …\n       " \
              "hecks quality_control check_generated_domains --promote <finding-dir> --name <stress_domain_name>"

      Generator = Hecks::Fuzzing::DomainGenerator

      # Generates, checks and reports.
      #
      # @param argv [Array<String>] the flags in the usage line
      # @param root [String] the repository root
      # @param env [Hash{String => String}] `QA_GENERATED_DOMAINS_PER_TICK` overrides the count of
      #   `--from-dials`
      # @return [Integer] 0 clean, 2 a finding, 1 an operational error
      # @raise [SystemExit] on a bad argument or a missing file
      def self.call(argv, root:, env: ENV)
        new(root: root, env: env).call(argv)
      end

      # @param root [String] the repository root
      # @param env [Hash{String => String}] `QA_GENERATED_DOMAINS_PER_TICK` overrides the count of
      #   `--from-dials`
      def initialize(root:, env: ENV)
        @root = root
        @env = env
      end

      # @param argv [Array<String>] the flags in the usage line
      # @return [Integer] the exit status
      # @raise [SystemExit] on a bad argument or a missing file
      def call(argv)
        @options = parse(argv.dup)
        return EXIT_OK if @options == :help
        return check_one if @options[:check]
        return promote if @options[:promote]
        return EXIT_OK if @options[:from_dials] && !dials_on?

        run
      end

      private

      def dial(name, fallback)
        return fallback unless defined?(::QualityControlDials) && ::QualityControlDials.const_defined?(name)

        ::QualityControlDials.const_get(name)
      end

      # `--from-dials` is how `hecks quality_control sweep.tick` runs this. The dials come from the
      # text of the bluebook before `Hecks.bluebook`, so the ledger's Postgres is not needed.
      # `QA_GENERATED_DOMAINS_PER_TICK` overrides the count for one run.
      #
      # @return [Boolean] false when the dials turn the step off, true once they are applied
      def dials_on?
        dials_path = File.join(@root, "lib/hecks/quality_control/quality_control.bluebook")
        eval(File.read(dials_path).split(/^Hecks\.bluebook/).first, TOPLEVEL_BINDING, dials_path)
        # rubocop:enable Security/Eval
        per_tick = Integer(@env.fetch("QA_GENERATED_DOMAINS_PER_TICK", dial(:GENERATED_DOMAINS_PER_TICK, 0)))
        if per_tick.zero?
          puts "generated domains: off (QualityControlDials::GENERATED_DOMAINS_PER_TICK is 0)"
          return false
        end
        @options.merge!(domains: per_tick, rust: dial(:GENERATED_DOMAINS_RUST, false),
                        seeds: dial(:GENERATED_DOMAIN_SEEDS, 5), adversarial: dial(:ADVERSARIAL_FRACTION, 0.3).to_f)
        true
      end

      def run
        start = @options[:start] || (Time.now.to_i % 1_000_000)
        # `-<pid>`: two runs started in the same second must not share domain directories.
        run_dir = File.join(@root, "tmp/qa-generated/run-#{start}-#{Process.pid}")
        prepare_scratch
        announce_run(start, run_dir)

        counts = Hash.new(0)
        findings = []
        # `--blueprint FILE` re-checks one saved blueprint through the same check/shrink/report
        # path.
        blueprints(start).each { |seed, blueprint| check_blueprint(seed, blueprint, run_dir, counts, findings) }
        report(counts, findings)
      end

      def prepare_scratch
        @scratch = File.join(@root, "tmp/qa-generated/rust")
        @options[:domains] = @options[:sources].size if @options[:sources].any?
        sync_scratch! if @options[:rust]
      end

      def check_blueprint(domain_seed, blueprint, run_dir, counts, findings)
        root = File.join(run_dir, domain_seed.to_s)
        result = evaluate(blueprint, root)
        counts[tally_key(result)] += 1
        puts status_line(result, blueprint_label(domain_seed, blueprint))
        findings << record_finding(blueprint, result, root).merge(seed: domain_seed) if tally_key(result) == :found
      end

      def blueprint_label(domain_seed, blueprint)
        label = "domain #{domain_seed} [#{blueprint["forms"].join("+")}]"
        blueprint["source"] ? label : "#{label} #{blueprint["aggregates"].size} aggregate(s)"
      end

      # @return [Symbol] the count a result adds to: `:clean`, `:invalid`, `:error` or `:found`
      def tally_key(result)
        %w[clean invalid error].include?(result["status"]) ? result["status"].to_sym : :found
      end

      def status_line(result, label)
        case result["status"]
        when "clean" then "  #{label}: clean (#{result["seeds_run"]} seed(s))"
        when "invalid", "error" then "  #{label}: #{result["status"].upcase} — #{result["error"]}"
        else found_line(result, label)
        end
      end

      def found_line(result, label)
        "  #{label}: FOUND SOMETHING (#{result["mode"]}: #{result["signature"].join(", ")}) — " \
          "shrinking the domain…"
      end
    end
  end
end
