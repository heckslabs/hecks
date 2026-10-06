# frozen_string_literal: true

require "json"
require "open3"
require_relative "../../../hecks"
require_relative "../../fuzzing/form_census"
require_relative "qa_domain_novelty/verdict"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control target.judge_novelty`: does a new stress domain earn
    # its place? It is the gate before a domain becomes a `Target`.
    #
    #   hecks quality_control target.judge_novelty <domain-path> [--against <path> ...]
    #
    # A domain is new when it puts two forms together on one aggregate that no existing target does
    # (`Hecks::Fuzzing::FormCensus`). It is compared against the ledger's `Target.path` rows unless
    # `--against` names others. "Nothing new" can also mean the domain's form is not yet named in
    # `FormCensus::FORMS`.
    #
    # Exit codes: 0 new pair found; 1 no new pair; 2 usage or wrong path shape.
    class QaDomainNovelty
      include Verdict

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
        present, existing_source = comparison_set(candidate, against)
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

      # The domains to compare against that exist on disk, and where they came from.
      def comparison_set(candidate, against)
        existing_source = against.empty? ? "the ledger's Target.path rows" : "--against"
        existing = (against.empty? ? ledger_target_paths : against).map { |path| normalize(path) }.uniq
        [present_domains(candidate, existing), existing_source]
      end

      def present_domains(candidate, existing)
        own = existing.select { |path| path == normalize(candidate) }
        puts "note: #{candidate} is already a target — left out of the comparison" unless own.empty?

        missing, present = (existing - own).partition { |path| Hecks::Fuzzing::FormCensus.bluebook_files(path).nil? }
        missing.each { |path| warn "skipping #{path}: no bluebook/*.bluebook on disk" }
        present
      end

      def parse(argv)
        before, against = split_at_against(argv)
        raise UsageError, "unexpected argument #{before[1].inspect}" if before.size > 1
        raise UsageError, "no candidate domain given" if before.empty?
        raise UsageError, "--against needs at least one path" if against == []

        [before.first, against || []]
      end

      # The arguments before the first `--against`, and the paths after it (nil without the flag).
      def split_at_against(argv)
        split = argv.index("--against")
        return [argv, nil] unless split

        [argv.first(split), argv.drop(split + 1).reject { |arg| arg == "--against" }]
      end

      # `hecks project_rust` reads exactly `<name>/bluebook/<name>.bluebook`, so refuse anything
      # else early.
      def refuse_unless_stress_domain_shaped!(path)
        expected = File.join(path, "bluebook", "#{File.basename(path)}.bluebook")
        return if File.file?(expected)

        raise UsageError, "#{path} is not shaped like a stress domain: expected #{expected} to exist " \
                          "(`<name>/bluebook/<name>.bluebook` — a flat file breaks `hecks project_rust`; " \
                          "see qa/stress_domains/ledger_ordering/NOTES.md)"
      end

      # The ledger's target paths via one read-only `ask`; never boots the ledger in this process.
      def ledger_target_paths
        out, err, status = Open3.capture3("bundle", "exec", "ruby", File.join(@root, "exe/hecks"),
                                          "run", "qa/bluebook", "ask", "target.all", chdir: @root)
        unless status.success?
          warn "hecks quality_control judge_novelty: could not read the ledger's targets (hecks run qa/bluebook ask " \
               "target.all exited #{status.exitstatus}):\n#{err}"
          warn "pass --against <path> ... to run without the ledger"
          raise Stopped
        end

        JSON.parse(out).map { |row| row.dig("path", "value") }.compact
      end

      def normalize(path) = File.expand_path(path, @root)
    end
  end
end
