# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaSweep
      # The seeds of a single-target sweep: each one generated, checked and logged, then the checks
      # made once per sweep, and the shrinking of the first surprise.
      module SeedLoop
        private

        # @return [Hash, nil] the first surprise, or nil when every check held
        def run_seeds
          # One campaign per sweep, resumed from a prior tick's corpus for this exact (target, mode)
          # so guided generation's knowledge compounds across ticks instead of rebuilding an
          # identical corpus from an identical trace every time. Nil when guided generation is off,
          # or this is a seedless-only sweep that will never record anything into it.
          @coverage_path = coverage_corpus_path(@target_reference, @mode) if @guided_generation && @seeded_modes.any?
          @campaign = build_campaign
          surprise = seed_loop || structural_skip_step || era_boundary_step
          shrink_surprise(surprise)
          surprise
        ensure
          # Drops this run's disposable schemas whether the sweep ends clean, surprised or crashes;
          # the databases stay. Persists whatever this run's campaign learned, clean, surprised or
          # crashed alike: the corpus a surprised run built up to that point is still real coverage
          # a later tick should not have to rediscover from scratch.
          drop_scratch_schemas
          save_coverage_state!(@coverage_path, @campaign) if @campaign
        end

        def build_campaign
          return unless @coverage_path

          saved = load_coverage_state(@coverage_path)
          if saved
            Hecks::Fuzzing::CoverageCampaign.load(saved, splice_probability: @corpus_splice_probability,
                                                         favor_count:        @favor_rare_verbs)
          else
            Hecks::Fuzzing::CoverageCampaign.new(splice_probability: @corpus_splice_probability,
                                                 favor_count:        @favor_rare_verbs)
          end
        end

        # A seedless-only sweep skips the loop so it never claims to have generated sequences.
        def seed_loop
          return unless @seeded_modes.any?

          surprise = nil
          ((@seed_offset + 1)..(@seed_offset + @seeds)).each do |seed|
            surprise = run_seed(seed)
            break if surprise
          end
          puts "  #{@campaign.summary}" if @campaign
          surprise
        end

        # @return [Hash, nil] the seed's result with its surprised checks, or nil when every
        #   check held
        def run_seed(seed)
          result, runtime = measured_seed(seed)
          @campaign.record(seed, result[:plan], result[:trace], runtime: runtime) if @campaign && result[:trace]

          surprised = log_seed_checks(result)
          if surprised.empty?
            puts "  seed #{seed}: held (#{check_modes(result[:checks])})"
            return nil
          end

          puts "  seed #{seed}: SURPRISED (#{check_modes(surprised)})"
          result.merge(seed: seed, checks: surprised)
        end

        # The seed's result, and the runtime lines and branches it reached when the dial asks for
        # that feedback; nil otherwise, so a campaign falls back to tuples alone.
        def measured_seed(seed)
          return [run_one_seed(@mode, seed), nil] unless @campaign && @runtime_coverage_feedback

          Hecks::Fuzzing::RuntimeCoverage.measure { run_one_seed(@mode, seed) }
        end

        def check_modes(checks)
          checks.map { |c| c[:mode] }.join(", ")
        end

        # Every mode's check is logged before the loop decides, so a seed that held differentially
        # but surprised on properties records both.
        #
        # @return [Array<Hash>] the checks that surprised
        def log_seed_checks(result)
          result[:checks].reject do |check|
            log_and_mark(check)
            check[:clean]
          end
        end

        def log_and_mark(check)
          @sweep = log_check!(@sweep, subject: check[:subject], expectation: check[:expectation])
          sequence = @sweep.checks.last[:sequence][:value]
          if check[:clean]
            mark_held!(@sweep, sequence, check[:observation])
          else
            mark_surprised!(@sweep, sequence, check[:observation], @target_reference)
          end
        end

        # Structural-skip check only after a differential loop that ran clean to the end.
        def structural_skip_step
          return unless @mode == :differential && @active_modes.include?(:structural_skip_report)

          check = structural_skip_check(@differ, @binary, @structural_boundary)
          log_and_mark(check)
          step_result("structural skips", check)
        end

        # Era-boundary check, once per sweep, independent of the primary seat; skipped once anything
        # surprised. A target with no lineage logs no Check: holding one would report an unaudited
        # target as clean.
        def era_boundary_step
          return unless @active_modes.include?(:era_boundary)

          check = era_boundary_check(@domain_path)
          if check[:skip]
            puts "  era boundary: #{check[:observation]} — no Check logged"
            return nil
          end

          log_and_mark(check)
          step_result("era boundary", check)
        end

        # @return [Hash, nil] a surprise for a check that surprised, nil for one that held
        def step_result(label, check)
          if check[:clean]
            puts "  #{label}: #{check[:observation]}"
            nil
          else
            puts "  #{label}: SURPRISED — #{check[:observation]}"
            { seed: nil, steps: [], checks: [check] }
          end
        end

        # Shrinks inside the guarded block: the parity schema is dropped afterwards, and candidates
        # need it.
        def shrink_surprise(surprise)
          return unless surprise && surprise[:seed] && @shrink_budget.positive?

          surprise[:shrunk] = surprise[:checks].filter_map do |check|
            next unless Checks::SHRINKABLE_MODES.include?(check[:mode])

            puts "  shrinking [#{check[:mode]}] (#{surprise[:steps].size} steps, budget #{@shrink_budget})…"
            shrink_check(check, @mode, surprise[:steps])
          end
        end
      end
    end
  end
end
