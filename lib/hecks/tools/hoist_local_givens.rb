# frozen_string_literal: true

require_relative "../tools"
require_relative "hoist_local_givens/rewriting"

module Hecks
  module Tools
    # Hoists `given`s that two or more commands under one owner repeat verbatim into a single
    # owner-level `given`, leaving bare references behind. Single-owner groups in example domains
    # only.
    #
    # It is not a `Hecks::Codemod::Runner`: hoisting adds an owner-level precondition, so the
    # exported IR cannot stay byte-identical. The invariant checked instead is each command's
    # effective rules.
    #
    # The `given` is inserted right after the owner's opening line: `command` calls are deferred
    # to `drain_pending!`, so the position of `given` inside the owner does not matter (ADR 0028).
    #
    #   hecks hoist_local_givens [--dry-run]
    module HoistLocalGivens
      # One rule several commands of an owner repeat.
      Candidate = Struct.new(:description, :canonical, :owner, :locations, keyword_init: true)

      # What one example domain's run starts from: its files, their text and effective rules before
      # any edit, the path its result is reported under, and whether nothing is kept.
      Snapshot = Struct.new(:files, :originals, :before_rules, :path, :dry_run)

      extend Rewriting

      module_function

      # Rewrites every example domain that has a candidate, and prints one line for each.
      #
      # @param argv [Array<String>] `--dry-run` to restore every file after the rewrite is checked
      # @param root [String] the checkout (unused: the examples come from `Codemod`)
      # @return [Integer] 0
      def main(argv, root: Tools::ROOT)
        _ = root
        require "hecks"
        require "hecks/codemod"
        require "hecks/query_ir"
        dry_run = argv.include?("--dry-run")

        report(run_domains(dry_run), dry_run)
        0
      end

      # @param dry_run [Boolean] whether nothing is kept
      # @return [Array<Hash>] one outcome for each example domain that has bluebooks
      def run_domains(dry_run)
        Hecks::Codemod::EXAMPLE_ROOTS.filter_map do |domain_dir|
          bluebook_files = Dir.glob(File.join(domain_dir, "bluebook", "*.bluebook"))
          run_files(bluebook_files, dry_run: dry_run) unless bluebook_files.empty?
        end
      end

      # @param results [Array<Hash>] one outcome for each example domain
      # @param dry_run [Boolean] whether nothing was kept
      # @return [void]
      def report(results, dry_run)
        puts "== results (#{dry_run ? "DRY RUN — nothing written" : "applied"}) =="
        results.filter_map { |result| result_line(result) }.each { |line| puts line }
      end

      # @return [String, nil] the line that reports one outcome, nil for an outcome of no kind
      def result_line(result)
        case result[:status]
        when :clean   then "clean (no candidates): #{result[:file]}"
        when :applied then "APPLIED  #{result[:file]}: #{candidate_labels(result)}"
        when :skipped then "SKIPPED  #{result[:file]} (#{result[:reason]}): #{candidate_labels(result)}"
        end
      end

      def candidate_labels(result)
        result[:candidates].map { |c| "#{c.owner}##{c.description.inspect} (#{c.locations.size} locations)" }.join(", ")
      end

      # Grouped by owner as well as description: identical rules recur across unrelated
      # aggregates, and a cross-owner match must not block hoisting the single-owner ones.
      #
      # @param registry [Object] the booted bluebooks
      # @return [Array<Candidate>] the rules to hoist
      def find_candidates(registry)
        groups = Hecks::QueryIR.collect_rules(registry)
                               .select { |r| r.kind == "given" }
                               .group_by { |r| [r.description, r.canonical, Hecks::QueryIR.owner_of(r.location)] }
        groups.filter_map do |(description, canonical, owner), rules|
          next unless hoistable?(rules)

          Candidate.new(description: description, canonical: canonical, owner: owner,
                        locations: rules.map(&:location))
        end
      end

      # Two or more occurrences, none of them an owner-level "(declared)" rule, which is already
      # hoisted for this owner.
      def hoistable?(rules)
        rules.size >= 2 && rules.none? { |r| r.location.end_with?(" (declared)") }
      end

      # Every command's effective rule set (block-declared or referenced) must be unchanged.
      # Owner-level "(declared)" entries are excluded: they are what is meant to differ.
      #
      # @param registry [Object] the booted bluebooks
      # @return [Hash{String => Array}] each command's rules, by location
      def command_rule_map(registry)
        Hecks::QueryIR.collect_rules(registry)
                      .reject { |r| r.location.end_with?(" (declared)") }
                      .group_by(&:location)
                      .transform_values { |rules| rules.map { |r| [r.kind, r.description, r.canonical] }.sort }
      end

      # @param files [Array<String>] one example domain's bluebook files
      # @param dry_run [Boolean] whether to judge the edit in memory and write nothing
      # @return [Hash] `file`, `status` (`:clean`, `:applied`, `:skipped`), and the candidates
      def run_files(files, dry_run:)
        snapshot = snapshot_of(files.sort, dry_run)
        candidates = find_candidates(Hecks::Codemod.load_bluebook(snapshot.files))
        return { file: snapshot.path, status: :clean } if candidates.empty?

        texts = snapshot.originals.transform_values(&:dup)
        applied = candidates.select { |candidate| hoist_into(snapshot.files, texts, candidate) }
        return no_match(snapshot) if applied.empty?

        judge_edit(snapshot, texts, applied)
      end

      # The files' text and effective rules, taken before any candidate is applied.
      #
      # @return [Snapshot]
      def snapshot_of(files, dry_run)
        originals = files.to_h { |file| [file, File.read(file)] }
        before_rules = command_rule_map(Hecks::Codemod.load_bluebook(files))
        path = files.one? ? files.first : File.dirname(files.first)
        Snapshot.new(files, originals, before_rules, path, dry_run)
      end

      # Applies the candidate to the first file it fits, in `texts`.
      #
      # @return [Boolean] whether any file took it
      def hoist_into(files, texts, candidate)
        target = files.find { |file| apply_candidate(texts[file], candidate).last }
        return false unless target

        texts[target], changed = apply_candidate(texts[target], candidate)
        changed
      end

      def no_match(snapshot)
        { file: snapshot.path, status: :skipped, reason: "no candidate matched its own source text", candidates: [] }
      end

      # Stages the edit, reboots on it, and keeps it only when every command's rules held.
      #
      # @return [Hash] the outcome: `:applied`, or `:skipped` with the reason it was reverted
      def judge_edit(snapshot, texts, applied)
        texts.each { |file, text| Hecks::Codemod.stage(file, text, dry_run: snapshot.dry_run) }
        after_rules, error = Hecks::Codemod.safely { command_rule_map(Hecks::Codemod.load_bluebook(snapshot.files)) }
        held = after_rules == snapshot.before_rules
        revert(snapshot) if snapshot.dry_run || !held
        return { file: snapshot.path, status: :applied, candidates: applied } if held

        { file: snapshot.path, status: :skipped, reason: revert_reason(error), candidates: applied }
      end

      # Puts every file's original text back.
      def revert(snapshot)
        snapshot.originals.each { |file, text| Hecks::Codemod.unstage(file, text, dry_run: snapshot.dry_run) }
      end

      def revert_reason(error)
        return "reboot raised after edit (#{error}) — reverted" if error

        "a command's own effective rule set changed after edit — reverted"
      end
    end
  end
end
