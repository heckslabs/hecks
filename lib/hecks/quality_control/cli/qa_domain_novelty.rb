# frozen_string_literal: true

require "json"
require "open3"
require_relative "../../../hecks"
require_relative "../../fuzzing/form_census"

module Hecks
  module QualityControlCli
    # The command behind `bin/qa_domain_novelty`: does a new stress domain earn its place? It is
    # the gate before a domain becomes a `Target`.
    #
    #   bin/qa_domain_novelty <domain-path> [--against <path> ...]
    #
    # A domain is new when it puts two forms together on one aggregate that no existing target does
    # (`Hecks::Fuzzing::FormCensus`). It is compared against the ledger's `Target.path` rows unless
    # `--against` names others. "Nothing new" can also mean the domain's form is not yet named in
    # `FormCensus::FORMS`.
    #
    # Exit codes: 0 new pair found; 1 no new pair; 2 usage or wrong path shape.
    class QaDomainNovelty
      EXIT_NOVEL = 0
      EXIT_NOTHING = 1
      EXIT_USAGE = 2

      USAGE = "usage: hecks quality_control judge_novelty <domain-path> [--against <path> ...]"

      # Judges the candidate.
      #
      # @param argv [Array<String>] the candidate's path, then optionally `--against` and paths
      # @param root [String] the repository root
      # @return [Integer] 0 when the candidate earns its place, 1 when it does not, 2 for a usage
      #   error
      def self.call(argv, root:)
        new(root: root).call(argv)
      end

      # @param root [String] the repository root
      def initialize(root:)
        @root = root
      end

      # @param argv [Array<String>] the candidate's path, then optionally `--against` and paths
      # @return [Integer] the exit status
      def call(argv)
        candidate, against = parse(argv)
        refuse_unless_stress_domain_shaped!(normalize(candidate))
        existing_source = against.empty? ? "the ledger's Target.path rows" : "--against"
        existing = (against.empty? ? ledger_target_paths : against).map { |path| normalize(path) }.uniq
        own = existing.select { |path| path == normalize(candidate) }
        existing -= own
        puts "note: #{candidate} is already a target — left out of the comparison" unless own.empty?

        missing, present = existing.partition { |path| Hecks::Fuzzing::FormCensus.bluebook_files(path).nil? }
        missing.each { |path| warn "skipping #{path}: no bluebook/*.bluebook on disk" }
        judge(candidate, present, existing_source)
      rescue UsageError => e
        warn e.message
        warn USAGE
        EXIT_USAGE
      rescue Stopped
        EXIT_USAGE
      end

      private

      # Raised for a wrong command line or path shape; it ends the run with `EXIT_USAGE`.
      class UsageError < StandardError; end

      # Raised once the reason has been printed; it ends the run with `EXIT_USAGE`.
      class Stopped < StandardError; end

      def parse(argv)
        candidate = nil
        against = []
        mode = :candidate
        argv.each do |arg|
          if arg == "--against"
            mode = :against
          elsif mode == :against
            against << arg
          elsif candidate.nil?
            candidate = arg
          else
            raise UsageError, "unexpected argument #{arg.inspect}"
          end
        end
        raise UsageError, "no candidate domain given" if candidate.nil?
        raise UsageError, "--against needs at least one path" if mode == :against && against.empty?

        [candidate, against]
      end

      # `bin/project_rust` reads exactly `<name>/bluebook/<name>.bluebook`, so refuse anything else
      # early.
      def refuse_unless_stress_domain_shaped!(path)
        expected = File.join(path, "bluebook", "#{File.basename(path)}.bluebook")
        return if File.file?(expected)

        raise UsageError, "#{path} is not shaped like a stress domain: expected #{expected} to exist " \
                          "(`<name>/bluebook/<name>.bluebook` — a flat file breaks bin/project_rust; " \
                          "see qa/stress_domains/ledger_ordering/NOTES.md)"
      end

      # The ledger's target paths via one read-only `ask`; never boots the ledger in this process.
      def ledger_target_paths
        out, err, status = Open3.capture3("bundle", "exec", "ruby", File.join(@root, "bin/run"),
                                          "qa/bluebook", "ask", "target.all", chdir: @root)
        unless status.success?
          warn "bin/qa_domain_novelty: could not read the ledger's targets (bin/run qa/bluebook ask " \
               "target.all exited #{status.exitstatus}):\n#{err}"
          warn "pass --against <path> ... to run without the ledger"
          raise Stopped
        end

        JSON.parse(out).map { |row| row.dig("path", "value") }.compact
      end

      def normalize(path) = File.expand_path(path, @root)

      def judge(candidate, present, existing_source)
        census = Hecks::Fuzzing::FormCensus.census(normalize(candidate))
        candidate_pairs = Hecks::Fuzzing::FormCensus.covered_pairs(census)
        existing_pairs = present.each_with_object(Hash.new { |h, k| h[k] = [] }) do |path, covered|
          Hecks::Fuzzing::FormCensus.covered_pairs(Hecks::Fuzzing::FormCensus.census(path)).each do |pair, names|
            covered[pair].concat(names.map { |name| "#{name} (#{path.delete_prefix("#{@root}/")})" })
          end
        end
        new_pairs = candidate_pairs.reject { |pair, _| existing_pairs.key?(pair) }

        puts "candidate: #{candidate} — #{census.size} aggregate(s), #{candidate_pairs.size} form pair(s) met"
        puts "against:   #{present.size} domain(s) from #{existing_source}, " \
             "#{existing_pairs.size} form pair(s) met between them"
        puts
        return nothing_new(candidate) if new_pairs.empty?

        width = new_pairs.keys.map(&:size).max
        puts "new pair(s) — met on one aggregate here, on none of the existing targets:"
        new_pairs.sort.each { |pair, names| puts "  #{pair.ljust(width)}  #{names.uniq.join(', ')}" }
        puts
        puts "#{new_pairs.size} new pair(s) — #{candidate} earns its place."
        EXIT_NOVEL
      end

      def nothing_new(candidate)
        puts "no new pair — every pair of forms #{candidate} puts together on one aggregate is already met " \
             "by an existing target. Either the domain is not new, or the form it exists for is not yet " \
             "named in Hecks::Fuzzing::FormCensus::FORMS (lib/hecks/fuzzing/form_census.rb) — name it " \
             "there first, citing the gap it is one step from, and run this again."
        puts
        puts "READ THAT AS A QUESTION ABOUT THE CENSUS, NOT A VERDICT ON THE DOMAIN. This gate measures " \
             "ONE AGGREGATE's own declared forms, so a domain whose point is a chapter-level construct — " \
             "a policy, an `across` target, a process manager, a read model's own group_by/median, an " \
             "outbox, a dry run — is invisible to it by construction, not by omission. `corrects` and " \
             "`role_gated` were exactly that: declared all over the corpus, unnamed here, so this line " \
             "told three stress domains built around retroactive correction that they were redundant " \
             "(their own NOTES.md each say so). If that is your domain's case, say which construct it " \
             "exists for in its NOTES.md and keep it."
        EXIT_NOTHING
      end
    end
  end
end
