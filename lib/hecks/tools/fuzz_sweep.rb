# frozen_string_literal: true

require "json"
require "tmpdir"
require "tempfile"
require "etc"
require "fileutils"
require_relative "../tools"

module Hecks
  module Tools
    # Fuzzes domains with generated command and query sequences, replaying each and checking the
    # properties, then shrinks each distinct finding and saves it under `tmp/fuzz-failures/`.
    #
    #   hecks fuzz [domain] [--seeds N] [--steps N] [--workers N] [--adapter memory|sqlite|postgres]
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
        return 1 unless options

        return 1 if options[:adapter] == :postgres && !postgres_reachable?

        # Every discoverable domain, so one added anywhere is swept without a list. Paths the sweep
        # cannot boot are routed by Hecks::Corpus::ROUTES to the check that owns them.
        domains = options[:domain] ? [options[:domain]] : Hecks::Corpus.fuzzable_domains(root)
        # One child per core; a real Postgres runs one at a time.
        workers = options[:workers] || (options[:adapter] == :postgres ? 1 : Etc.nprocessors)
        ok = sweep(domains, workers, options, root)

        puts(ok ? "CLEAN — no generated sequence broke a property or the interpreter." : "FUZZ FOUND SOMETHING.")
        ok ? 0 : 1
      end

      # @param args [Array<String>] the command line, consumed
      # @return [Hash, nil] `seeds`, `steps`, `workers`, `adapter` and `domain`; nil after a refusal
      def parse(args)
        options = { seeds: 20, steps: 30, workers: nil, adapter: :memory, domain: nil }
        until args.empty?
          case (arg = args.shift)
          when "--seeds" then options[:seeds] = Integer(args.shift)
          when "--steps" then options[:steps] = Integer(args.shift)
          when "--workers" then options[:workers] = Integer(args.shift)
          when "--adapter"
            options[:adapter] = args.shift.to_s.downcase.to_sym
            unless ADAPTERS.include?(options[:adapter])
              warn "unknown --adapter #{options[:adapter]} — memory, sqlite, or postgres"
              return nil
            end
          else options[:domain] = arg
          end
        end
        options
      end

      # `postgres` needs a reachable local server and is slower per dispatch, so pass smaller
      # `--seeds` and `--steps`.
      #
      # @return [Boolean] whether a local Postgres answers; warns why when it does not
      def postgres_reachable?
        require "pg"
        PG.connect(dbname: "postgres").close
        true
      rescue LoadError, PG::Error => e
        warn "--adapter postgres needs a reachable local Postgres — #{e.class}: #{e.message}"
        false
      end

      # @param domains [Array<String>] the domain directories
      # @param workers [Integer] how many children may run at once
      # @param options [Hash] the parsed options
      # @param root [String] the checkout
      # @return [Boolean] whether every domain was clean
      def sweep(domains, workers, options, root)
        if workers > 1 && domains.size > 1
          # Booted here so every child inherits the grammar instead of each paying for a cold boot.
          require "hecks/bluebook/meta_validator"
          Hecks::Bluebook::MetaValidator.grammar_registry
          $stdout.flush
          fuzz_in_pool(domains, workers) do |domain|
            fuzz_domain(domain, options[:seeds], options[:steps], options[:adapter], root)
          end
        else
          domains.reduce(true) do |all_ok, domain|
            fuzz_domain(domain, options[:seeds], options[:steps], options[:adapter], root) && all_ok
          end
        end
      end

      # Writes a shrunk (or original) step sequence to disk as a replayable script.
      #
      # @param steps [Array<Hash>] the step sequence to save
      # @param path [String] the file path to write the script to
      # @param seed [Integer] the seed that produced `steps`, recorded in the script's own note
      # @param domain_name [String] the domain's basename, for the script's `name` field
      # @return [void]
      def write_script(steps, path, seed, domain_name)
        File.write(path, JSON.pretty_generate(
                           name:  "#{domain_name}-fuzz",
                           note:  "generated by hecks fuzz — seed #{seed}",
                           steps: steps
                         ))
      end

      # An exception escaping Replay's per-step isolation is an interpreter defect, not a domain
      # refusal.
      #
      # @param domain [String] the domain directory
      # @param steps [Array<Hash>] the sequence to replay
      # @param adapter [Symbol] the persistence to boot on
      # @return [Array(Symbol, String)] the verdict (`:clean`, `:property_violation`, `:crash`) and
      #   its message
      def outcome(domain, steps, adapter = :memory)
        history = Hecks::Fuzzing::Replay.call(domain, steps, adapter: adapter)
        violations = Hecks::Fuzzing::Properties.check(history).reject { |_, result| result == true }
        return [:clean, nil] if violations.empty?

        [:property_violation, violations.map { |name, message| "#{name}: #{message}" }.join("; ")]
      rescue StandardError => e
        [:crash, "#{e.class}: #{e.message}"]
      end

      # Groups findings by property name or exception class, stable across shrink candidates.
      #
      # @param message [String, nil] a finding's message
      # @return [String] the property name or exception class it opens with
      def signature_of(message)
        return "unknown" unless message

        message.split(":").first
      end

      # A compound finding that mixes a known shape with any other offender is not known and still
      # fails.
      #
      # @param name [String] the domain's name
      # @param failure [Hash] a finding: `signature` and `message`
      # @return [Boolean] whether every offender is an allowlisted one
      def known_finding?(name, failure)
        matchers = KNOWN_FUZZ_FINDINGS.dig(name, failure[:signature])
        return false unless matchers

        failure[:message].split("; ").all? { |chunk| matchers.any? { |regex| regex.match?(chunk) } }
      end

      # Skips only exact, already-tracked wiring gaps; any other WiringError is re-raised.
      #
      # @param error [Hecks::Runtime::WiringError] what generating a sequence raised
      # @return [Symbol] a key of `SKIPPED_DOMAIN_REASONS`
      def known_unfuzzable_wiring_gap(error)
        case error.message
        when %r{a compute/rekey rule is declared}
          # compute/rekey needs an era/Postgres migration, so it cannot boot under IsolatedBoot's
          # Memory rebind. Real coverage lives in spec/adapters/driven/postgres_era/*_spec.rb.
          :skip_compute_rekey
        else
          raise error
        end
      end

      # Draws seeds until `seeds` results execute or the draw cap is hit.
      #
      # @param domain [String] the domain directory
      # @param seeds [Integer] how many executing seeds to ask for
      # @param steps [Integer] how many steps each sequence asks for
      # @param adapter [Symbol] the persistence to boot on
      # @param root [String] the checkout
      # @return [Boolean] true if clean or skipped
      def fuzz_domain(domain, seeds, steps, adapter = :memory, root = Tools::ROOT)
        domain = domain.chomp("/")
        name = File.basename(domain)
        puts "── #{name}#{" (#{adapter})" unless adapter == :memory}"

        failures = []
        clean = 0
        drawn = 0
        cap = seeds * DRAW_LIMIT

        while (clean + failures.length) < seeds && drawn < cap
          drawn += 1
          seed = drawn
          generated = begin
            Hecks::Fuzzing::SequenceGenerator.generate(domain, seed: seed, steps: steps, adapter: adapter)
          rescue Hecks::Runtime::WiringError => e
            known_unfuzzable_wiring_gap(e)
          end
          if (reason = SKIPPED_DOMAIN_REASONS[generated])
            puts "   skipped — #{reason} (not fuzzable under :#{adapter})"
            return true
          end
          verdict, message = outcome(domain, generated, adapter)

          if verdict == :clean
            determinism = Hecks::Fuzzing::Properties.replay_is_deterministic(domain, generated, adapter: adapter)
            if determinism == true
              clean += 1
              next
            end
            verdict = :nondeterminism
            message = determinism
          end

          failures << { seed: seed, steps: generated, verdict: verdict, message: message,
                        signature: "#{verdict}: #{signature_of(message)}" }
        end

        # Known findings print but count as clean, so the sweep does not read as short.
        known, failures = failures.partition { |failure| known_finding?(name, failure) }
        known.each do |failure|
          puts "   KNOWN (allowlisted, not failing) — #{failure[:signature]} — #{failure[:message]}"
        end
        clean += known.length

        report(domain, name, seeds, drawn, clean, failures, adapter, root)
      end

      # Shrinks steps, then arguments, keeping a removal only while the same finding reproduces.
      #
      # @param domain [String] the domain directory
      # @param steps [Array<Hash>] the failing sequence
      # @param signature [String] the finding to keep
      # @param adapter [Symbol] the persistence to boot on
      # @return [Array<Hash>] the smallest sequence found
      def shrink(domain, steps, signature, adapter = :memory)
        Hecks::Fuzzing::Shrinker.call(steps) { |candidate| same_finding?(domain, candidate, signature, adapter) }.steps
      end

      # @param domain [String] the domain directory
      # @param candidate [Array<Hash>] a sequence to replay
      # @param signature [String] the finding to keep
      # @param adapter [Symbol] the persistence to boot on
      # @return [Boolean] whether the candidate sequence reproduces the finding
      def same_finding?(domain, candidate, signature, adapter)
        verdict, message = outcome(domain, candidate, adapter)
        "#{verdict}: #{signature_of(message)}" == signature
      end

      # @param step [Hash] one step of a sequence
      # @return [Hash] its arguments
      def args_of(step) = Hecks::Fuzzing::Shrinker.args_of(step)

      # The argument pass alone.
      #
      # @param domain [String] the domain directory
      # @param steps [Array<Hash>] the failing sequence
      # @param signature [String] the finding to keep
      # @param adapter [Symbol] the persistence to boot on
      # @return [Array<Hash>] the sequence with every argument the finding does not need dropped
      def shrink_arguments(domain, steps, signature, adapter = :memory)
        Hecks::Fuzzing::Shrinker.drop_arguments(steps, Hecks::Fuzzing::Shrinker::Meter.new(nil)) do |candidate|
          same_finding?(domain, candidate, signature, adapter)
        end
      end

      # Prints the final report, then shrinks and saves one repro script per distinct finding.
      #
      # @param domain [String] the domain directory
      # @param name [String] its name
      # @param seeds [Integer] how many executing seeds were asked for
      # @param drawn [Integer] how many were drawn
      # @param clean [Integer] how many ran clean
      # @param failures [Array<Hash>] the findings
      # @param adapter [Symbol] the persistence the sweep booted on
      # @param root [String] the checkout, where the repro scripts are saved
      # @return [Boolean] whether the domain had no findings
      # rubocop:disable-next Metrics/AbcSize
      def report(domain, name, seeds, drawn, clean, failures, adapter = :memory, root = Tools::ROOT) # rubocop:disable Naming/PredicateMethod
        executed = clean + failures.length
        puts "   #{executed} seeds executed (#{drawn} drawn) — #{clean} clean, #{failures.length} found something"

        if executed < seeds
          puts "   SHORT — asked for #{seeds} executing seeds and drew #{drawn} to find #{executed}."
          puts "          The generator is not reaching state ; this sweep proves less than it looks."
        end

        if failures.empty?
          puts
          return true
        end

        grouped = failures.group_by { |failure| failure[:signature] }
        puts "   #{grouped.size} distinct finding(s):"
        save_dir = File.join(root, "tmp/fuzz-failures")
        FileUtils.mkdir_p(save_dir)

        grouped.each_value.with_index(1) do |group, number|
          seeds_hit = group.map { |failure| failure[:seed] }
          smallest  = group.min_by { |failure| failure[:steps].length }

          puts
          puts "   (#{number}) #{group.first[:signature]} — #{group.first[:message]}"
          puts "       #{group.length} of #{seeds} seeds: #{seeds_hit.first(8).join(", ")}#{", …" if seeds_hit.length > 8}"

          shrunk = shrink(domain, smallest[:steps], smallest[:signature], adapter)
          save_path = File.join(save_dir, "#{name}-seed#{smallest[:seed]}.json")
          write_script(shrunk, save_path, smallest[:seed], name)

          puts "       shrunk #{smallest[:steps].length} steps -> #{shrunk.length}"
          puts "       reproduce: hecks run #{domain} #{save_path}"
        end

        puts
        false
      end

      # Forks one child per domain, up to `workers`, printing each child's output whole in domain
      # order. A child that crashes exits non-zero and counts as a finding.
      #
      # @param domains [Array<String>] the domain directories
      # @param workers [Integer] how many children may run at once
      # @yieldparam domain [String] a domain directory
      # @yieldreturn [Boolean] whether it was clean
      # @return [Boolean] true if every domain's child exited 0, false if any exited non-zero
      def fuzz_in_pool(domains, workers) # rubocop:disable Naming/PredicateMethod
        pending = domains.each_with_index.to_a
        running = {}
        results = {}
        until pending.empty? && running.empty?
          while running.size < workers && (domain, index = pending.shift)
            out = Tempfile.new("fuzz")
            pid = fork do
              $stdout.reopen(out)
              $stderr.reopen(out)
              exit(yield(domain) ? 0 : 1)
            end
            running[pid] = [index, out, Process.clock_gettime(Process::CLOCK_MONOTONIC)]
          end
          pid, status = Process.wait2
          index, out, started = running.delete(pid)
          results[index] = [status.success?, out, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
        end
        slowest = results.max_by(5) { |_, (_, _, seconds)| seconds }
                         .map { |index, (_, _, seconds)| "#{File.basename(domains[index])} #{seconds.round}s" }
        warn "slowest domains: #{slowest.join(", ")}"
        results.sort.map do |_, (clean, out, _)|
          out.rewind
          print out.read
          out.close!
          clean
        end.all?
      end
    end
  end
end
