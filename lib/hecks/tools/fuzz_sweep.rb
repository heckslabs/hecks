# frozen_string_literal: true

require "json"
require "tmpdir"
require "etc"
require_relative "../tools"
require_relative "fuzz_sweep/options"
require_relative "fuzz_sweep/findings"
require_relative "fuzz_sweep/reporting"
require_relative "fuzz_sweep/pool"

module Hecks
  module Tools
    # Fuzzes domains with generated command and query sequences, replaying each and checking the
    # properties, then shrinks each distinct finding and saves it under `tmp/fuzz-failures/`.
    #
    #   hecks fuzz [domain] [--seeds N] [--steps N] [--workers N] [--adapter memory|sqlite|postgres]
    #               [--persist-regressions]
    #
    # The sweep is single-runtime on purpose; the cross-runtime differential is
    # `spec/rust_conformance_fuzz_spec.rb`. Without a domain it sweeps every domain
    # `Hecks::Corpus.fuzzable_domains` finds, one forked child per core.
    module FuzzSweep
      # How many seeds are drawn for each seed that must execute.
      DRAW_LIMIT = 5

      # Domain name => failure signature => Regexps that every "; "-joined offender must match.
      # Entries excuse one named finding and are removed when its bug is fixed.
      KNOWN_FUZZ_FINDINGS = {}.freeze

      # Why a domain is skipped, by the reason `known_unfuzzable_wiring_gap` answers.
      SKIPPED_DOMAIN_REASONS = {
        skip_compute_rekey: "declares compute/rekey, which only an era/Postgres-bound boot can interpret"
      }.freeze

      # The persistence an ephemeral boot may use.
      ADAPTERS = %i[memory sqlite postgres].freeze

      # What drawing seeds for one domain found: how many ran clean, the findings, how many seeds
      # were drawn, and the reason the domain was skipped when it cannot be fuzzed.
      Draw = Struct.new(:clean, :failures, :drawn, :skipped)

      # What the sweep of one domain drew and found, for the final report.
      Result = Struct.new(:domain, :name, :seeds, :drawn, :clean, :failures, :adapter, :root, :persist)

      extend Options
      extend Findings
      extend Reporting
      extend Pool

      module_function

      # Runs a sweep as the command line asks.
      #
      # @param argv [Array<String>] a domain path, `--seeds N`, `--steps N`, `--workers N`,
      #   `--adapter memory|sqlite|postgres`
      # @param root [String] the checkout, where `tmp/fuzz-failures/` is written
      # @return [Integer] 0 when every domain is clean, 1 when a sequence found something or an
      #   argument is refused
      def main(argv, root: Tools::ROOT)
        require "hecks"
        require "hecks/fuzzing"
        options = parse(argv.dup)
        return 1 unless options && adapter_ready?(options)

        # Every discoverable domain, so one added anywhere is swept without a list. Paths the sweep
        # cannot boot are routed by Hecks::Corpus::ROUTES to the check that owns them.
        domains = options[:domain] ? [options[:domain]] : Hecks::Corpus.fuzzable_domains(root)
        ok = sweep(domains, worker_count(options), options, root)

        puts(ok ? "CLEAN — no generated sequence broke a property or the interpreter." : "FUZZ FOUND SOMETHING.")
        ok ? 0 : 1
      end

      # @param domains [Array<String>] the domain directories
      # @param workers [Integer] how many children may run at once
      # @param options [Hash] the parsed options
      # @param root [String] the checkout
      # @return [Boolean] whether every domain was clean
      def sweep(domains, workers, options, root)
        return sweep_serially(domains, options, root) unless workers > 1 && domains.size > 1

        # Booted here so every child inherits the grammar instead of each paying for a cold boot.
        require "hecks/bluebook/meta_validator"
        Hecks::Bluebook::MetaValidator.grammar_registry
        $stdout.flush
        fuzz_in_pool(domains, workers) { |domain| fuzz_with(options, domain, root) }
      end

      # @return [Boolean] whether every domain was clean
      def sweep_serially(domains, options, root)
        domains.reduce(true) { |all_ok, domain| fuzz_with(options, domain, root) && all_ok }
      end

      def fuzz_with(options, domain, root)
        fuzz_domain(domain, options[:seeds], options[:steps], options[:adapter], root, options[:persist])
      end

      # Draws seeds until `seeds` results execute or the draw cap is hit.
      #
      # @param domain [String] the domain directory
      # @param seeds [Integer] how many executing seeds to ask for
      # @param steps [Integer] how many steps each sequence asks for
      # @param adapter [Symbol] the persistence to boot on
      # @param root [String] the checkout
      # @param persist [Boolean] whether each distinct finding's minimized repro is also kept under
      #   `spec/corpus/regressions/`
      # @return [Boolean] true if clean or skipped
      def fuzz_domain(domain, seeds, steps, adapter = :memory, root = Tools::ROOT, persist = false)
        domain = domain.chomp("/")
        name = File.basename(domain)
        puts "── #{name}#{" (#{adapter})" unless adapter == :memory}"

        draw = draw_seeds(domain, seeds, steps, adapter)
        if draw.skipped
          puts "   skipped — #{draw.skipped} (not fuzzable under :#{adapter})"
          return true
        end

        result = Result.new(domain, name, seeds, draw.drawn, draw.clean, draw.failures, adapter, root, persist)
        report(settle_known(result))
      end

      # Known findings print but count as clean, so the sweep does not read as short.
      #
      # @param result [Result] what the sweep drew and found
      # @return [Result] the same result, with the allowlisted findings moved to `clean`
      def settle_known(result)
        known, result.failures = result.failures.partition { |failure| known_finding?(result.name, failure) }
        known.each do |failure|
          puts "   KNOWN (allowlisted, not failing) — #{failure[:signature]} — #{failure[:message]}"
        end
        result.clean += known.length
        result
      end

      # @return [Draw] the seeds drawn, stopping early when the domain cannot be fuzzed
      def draw_seeds(domain, seeds, steps, adapter)
        draw = Draw.new(0, [], 0, nil)
        cap = seeds * DRAW_LIMIT
        while (draw.clean + draw.failures.length) < seeds && draw.drawn < cap
          draw.drawn += 1
          generated = generate_sequence(domain, draw.drawn, steps, adapter)
          draw.skipped = SKIPPED_DOMAIN_REASONS[generated]
          return draw if draw.skipped

          record_seed(draw, domain, generated, adapter)
        end
        draw
      end

      # @return [Array<Hash>, Symbol] the sequence, or the key of the reason it cannot be generated
      def generate_sequence(domain, seed, steps, adapter)
        Hecks::Fuzzing::SequenceGenerator.generate(domain, seed: seed, steps: steps, adapter: adapter)
      rescue Hecks::Runtime::WiringError => e
        known_unfuzzable_wiring_gap(e)
      end

      # Files one drawn sequence under `draw` as clean or as a finding.
      def record_seed(draw, domain, generated, adapter)
        verdict, message = verdict_for(domain, generated, adapter)
        return draw.clean += 1 if verdict == :clean

        draw.failures << { seed: draw.drawn, steps: generated, verdict: verdict, message: message,
                           signature: "#{verdict}: #{signature_of(message)}" }
      end

      # @return [Array(Symbol, String)] the verdict, replaying a clean run once more to see that it
      #   repeats; and its message
      def verdict_for(domain, generated, adapter)
        verdict, message = outcome(domain, generated, adapter)
        return [verdict, message] unless verdict == :clean

        determinism = Hecks::Fuzzing::Properties.replay_is_deterministic(domain, generated, adapter: adapter)
        determinism == true ? [:clean, nil] : [:nondeterminism, determinism]
      end
    end
  end
end
