require "fileutils"
require "json"
require "tmpdir"
require_relative "operators"
require_relative "judge"
require_relative "selection"
require_relative "report"

module Hecks
  module Fuzzing
    module Mutation
      # Mutation testing of a domain's own checks: makes each small change `Operators` finds to a
      # copy of the domain, replays the same generated sequences, the domain's corpus script (when it
      # has one) and its `.behaviors` tests against the copy, and asks whether any check noticed.
      #
      # A mutant is killed when a fuzz property fails, the replay crashes, a corpus expectation goes
      # unmet or a behaviors test fails. It survives when its behavior differs from the unmutated
      # domain's and nothing failed: the checks have a hole there. It is unreached when no sequence
      # told it apart from the original, which is either an equivalent change or a part of the domain
      # the generator never gets to. A mutant that does not boot is invalid and counts toward no score.
      #
      # Deterministic: the sequences and the choice of mutants both come from `seed`.
      class Run
        # The checkout this file lives in, where a domain's corpus script is looked for.
        ROOT = File.expand_path("../../../..", __dir__)

        # The knobs of a run.
        #
        # @!attribute [r] seed
        #   @return [Integer] draws the sequences and the choice of mutants
        # @!attribute [r] budget
        #   @return [Integer] how many mutants to try at most
        # @!attribute [r] seeds
        #   @return [Integer] how many generated sequences each mutant is replayed against
        # @!attribute [r] steps
        #   @return [Integer] how many steps each sequence asks for
        # @!attribute [r] corpus
        #   @return [String, nil] a corpus script to replay too; found by the domain's name when nil
        # @!attribute [r] operators
        #   @return [Array<Symbol>, nil] restricts the run to these operators
        Settings = Struct.new(:seed, :budget, :seeds, :steps, :corpus, :operators, keyword_init: true)

        DEFAULTS = { seed: 1, budget: 25, seeds: 3, steps: 30, corpus: nil, operators: nil }.freeze

        # @param domain [String] the domain directory
        # @param options [Hash] any of `Settings`' members
        # @return [Report] what was tried and how each mutant ended
        def self.call(domain, **) = new(domain, Settings.new(**DEFAULTS, **)).call

        def initialize(domain, settings)
          @domain = domain.chomp("/")
          @settings = settings
        end

        # @return [Report] the mutants tried, each with its verdict
        def call
          plan = Plan.new(generate_sequences, corpus_script)
          baseline = Checks.baseline(@domain, plan)
          sites = Operators.sites(bluebook_sources)
          verdicts = chosen(sites).map { |site| judge(site, plan, baseline) }
          Report.new(facts(sites.size, plan), verdicts)
        end

        private

        def facts(available, plan)
          Report::Facts.new(File.basename(@domain), @settings.seed, available, plan.sequences.size, !plan.corpus.nil?)
        end

        def chosen(sites)
          Selection.pick(sites, budget: @settings.budget, seed: @settings.seed, operators: @settings.operators)
        end

        # The same sequences for every mutant, generated against the unmutated domain so each is
        # valid there and any difference is the mutation's.
        def generate_sequences
          Array.new(@settings.seeds) do |index|
            SequenceGenerator.generate(@domain, seed: @settings.seed + index, steps: @settings.steps,
                                                adversarial: index.odd? ? 0.3 : 0.0)
          end
        end

        def judge(site, plan, baseline)
          Dir.mktmpdir("hecks-mutant") do |tmp|
            copy = File.join(tmp, File.basename(@domain))
            FileUtils.cp_r(@domain, copy)
            path = File.join(copy, site.file)
            File.write(path, site.apply(File.readlines(path)).join)
            Judge.call(site, copy, plan, baseline)
          end
        end

        # @return [Hash{String => String}] each bluebook of the domain by path relative to it
        def bluebook_sources
          Dir.glob(File.join(@domain, "**", "*.bluebook")).to_h do |path|
            [path.delete_prefix("#{@domain}/"), File.read(path)]
          end
        end

        # The parsed corpus script: the one asked for, else the one of this domain's name.
        def corpus_script
          path = @settings.corpus || File.join(ROOT, "spec", "corpus", "#{File.basename(@domain)}.json")
          File.file?(path) ? JSON.parse(File.read(path)) : nil
        end
      end
    end
  end
end
