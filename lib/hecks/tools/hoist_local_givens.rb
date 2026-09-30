# frozen_string_literal: true

require_relative "../tools"

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
    #   bin/codemod_hoist_local_givens [--dry-run]
    module HoistLocalGivens
      # One rule several commands of an owner repeat.
      Candidate = Struct.new(:description, :canonical, :owner, :locations, keyword_init: true)

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

        results = Hecks::Codemod::EXAMPLE_ROOTS.filter_map do |domain_dir|
          bluebook_files = Dir.glob(File.join(domain_dir, "bluebook", "*.bluebook"))
          next if bluebook_files.empty?

          run_files(bluebook_files, dry_run: dry_run)
        end

        report(results, dry_run)
        0
      end

      # @param results [Array<Hash>] one outcome for each example domain
      # @param dry_run [Boolean] whether nothing was kept
      # @return [void]
      def report(results, dry_run)
        label = ->(c) { "#{c.owner}##{c.description.inspect} (#{c.locations.size} locations)" }

        puts "== results (#{dry_run ? 'DRY RUN — nothing written' : 'applied'}) =="
        results.each do |r|
          case r[:status]
          when :clean   then puts "clean (no candidates): #{r[:file]}"
          when :applied then puts "APPLIED  #{r[:file]}: #{r[:candidates].map(&label).join(', ')}"
          when :skipped then puts "SKIPPED  #{r[:file]} (#{r[:reason]}): #{r[:candidates].map(&label).join(', ')}"
          end
        end
      end

      # Grouped by owner as well as description: identical rules recur across unrelated
      # aggregates, and a cross-owner match must not block hoisting the single-owner ones.
      #
      # @param registry [Object] the booted bluebooks
      # @return [Array<Candidate>] the rules to hoist
      def find_candidates(registry)
        Hecks::QueryIR.collect_rules(registry)
                      .select { |r| r.kind == "given" }
                      .group_by { |r| [r.description, r.canonical, Hecks::QueryIR.owner_of(r.location)] }
                      .filter_map do |(description, canonical, owner), rules|
          next if rules.size < 2
          # An owner-level "(declared)" rule is already hoisted for this owner.
          next if rules.any? { |r| r.location.end_with?(" (declared)") }

          Candidate.new(description: description, canonical: canonical, owner: owner,
                        locations: rules.map(&:location))
        end
      end

      # The owner's own window: its opening line to the next `end` at the same indentation.
      # `collect_rules` yields a dotted owner ("Account.LedgerEntry") but the source spells the
      # bare name, so the last segment is matched; a name that is not unique in the file is
      # skipped.
      #
      # @param text [String] a bluebook's source
      # @param owner [String] the owner's dotted name
      # @return [Array(MatchData, Integer), nil] the opening line's match and the closing offset
      def owner_window(text, owner)
        bare_name = owner.split(".").last
        open_re = /^([ \t]*)(?:aggregate|entity)\s+"#{Regexp.escape(bare_name)}"\s+do\n/
        return nil if text.scan(open_re).size != 1

        open_match = text.match(open_re)
        indent = open_match[1]
        close_at = text.index(/^#{indent}end\n/, open_match.end(0))
        return nil unless close_at

        [open_match, close_at]
      end

      # Nested entity blocks are carved out of the scan: an entity may declare a `given` with the
      # same description but a different predicate.
      #
      # @param window [String] the owner's source
      # @return [Array<Array(String, Boolean)>] each stretch of source, and whether it is nested
      def strip_nested_entities(window)
        entity_re = /^([ \t]*)entity\s+"[^"]+"\s+do\n/
        segments  = []
        pos = 0

        while (m = window.match(entity_re, pos))
          end_match = window.match(/^#{m[1]}end\n/, m.end(0))
          break unless end_match

          segments << [window[pos...m.begin(0)], false]
          segments << [window[m.begin(0)...end_match.end(0)], true]
          pos = end_match.end(0)
        end
        segments << [window[pos..], false]
        segments
      end

      # A match needs the predicate to equal the candidate's canonical, not just the description:
      # the same words can carry a different rule (`disputed_by.status` vs
      # `account.customer.status`).
      #
      # @param predicate_src [String] a `given`'s block source
      # @param candidate [Candidate] the rule being hoisted
      # @return [Boolean] whether it is the same rule
      def matching_occurrence?(predicate_src, candidate)
        predicate_src.strip == candidate.canonical
      end

      # @param description [String] a `given`'s description
      # @return [Regexp] the line that declares it with a block
      def desc_pattern_for(description)
        /^([ \t]*)given\(#{Regexp.escape(description.inspect)}\)\s*\{([^\n}]*)\}\n/
      end

      # @param text [String] a bluebook's source
      # @param candidate [Candidate] the rule to hoist
      # @return [Array(String, Boolean)] the new source and whether the rule was hoisted
      def apply_candidate(text, candidate)
        bounds = owner_window(text, candidate.owner)
        return [text, false] unless bounds

        open_match, close_at = bounds
        window   = text[open_match.end(0)...close_at]
        segments = strip_nested_entities(window)
        pattern  = desc_pattern_for(candidate.description)

        outside_matches = segments.flat_map { |seg, nested| nested ? [] : seg.scan(pattern) }
                                  .select { |_, predicate_src| matching_occurrence?(predicate_src, candidate) }
        return [text, false] if outside_matches.size < 2

        # Indent one level inside the owner, not as deep as the occurrence in a command block.
        child_indent = "#{open_match[1]}  "
        new_given_line = "#{child_indent}given(#{candidate.description.inspect}) { #{candidate.canonical} }\n"

        bare_window = segments.map do |seg, nested|
          next seg if nested

          seg.gsub(pattern) do
            indent = Regexp.last_match(1)
            predicate_src = Regexp.last_match(2)
            if matching_occurrence?(predicate_src, candidate)
              "#{indent}given(#{candidate.description.inspect})\n"
            else
              Regexp.last_match(0)
            end
          end
        end.join

        new_text = text[0...open_match.end(0)] + new_given_line + bare_window + text[close_at..]
        [new_text, true]
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

      # Kept in one method: `originals` and `before_rules` must be captured before any candidate
      # is applied, and splitting would mean threading that snapshot through parameters.
      #
      # @param files [Array<String>] one example domain's bluebook files
      # @param dry_run [Boolean] whether to judge the edit in memory and write nothing
      # @return [Hash] `file`, `status` (`:clean`, `:applied`, `:skipped`), and the candidates
      # rubocop:disable-next Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def run_files(files, dry_run:)
        files = files.sort
        originals = files.to_h { |file| [file, File.read(file)] }
        before_rules = command_rule_map(Hecks::Codemod.load_bluebook(files))
        candidates = find_candidates(Hecks::Codemod.load_bluebook(files))
        result_path = files.one? ? files.first : File.dirname(files.first)

        return { file: result_path, status: :clean } if candidates.empty?

        texts = originals.transform_values(&:dup)
        applied = []
        candidates.each do |c|
          target = files.find { |file| apply_candidate(texts[file], c).last }
          next unless target

          text, changed = apply_candidate(texts[target], c)
          texts[target] = text
          applied << c if changed
        end

        if applied.empty?
          return { file: result_path, status: :skipped,
                   reason: "no candidate matched its own source text", candidates: [] }
        end

        texts.each { |file, text| Hecks::Codemod.stage(file, text, dry_run: dry_run) }
        after_rules, error = Hecks::Codemod.safely do
          command_rule_map(Hecks::Codemod.load_bluebook(files))
        end
        if dry_run || after_rules != before_rules
          originals.each { |file, text| Hecks::Codemod.unstage(file, text, dry_run: dry_run) }
        end

        if after_rules == before_rules
          { file: result_path, status: :applied, candidates: applied }
        else
          reason = if error
                     "reboot raised after edit (#{error}) — reverted"
                   else
                     "a command's own effective rule set changed after edit — reverted"
                   end
          { file: result_path, status: :skipped, reason: reason, candidates: applied }
        end
      end
    end
  end
end
