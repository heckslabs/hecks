require_relative "sweep"

module Hecks
  module Codemod
    # Runs one codemod rule across every example domain and the meta-domain,
    # verifying each candidate edit via IR diff before keeping it.
    class Runner
      # @return [#call] finds a booted registry's candidate edits
      attr_reader :find_candidates

      # @return [#call] applies one candidate to a file's text, answering the text and whether
      #   it changed
      attr_reader :apply_candidate

      # @return [#call] words a candidate for the report
      attr_reader :label

      def initialize(find_candidates:, apply_candidate:, label:)
        @find_candidates = find_candidates
        @apply_candidate = apply_candidate
        @label = label
      end

      def run(dry_run: false)
        results = { applied: [], skipped: [], clean: [] }
        run_example_domains(results, dry_run)
        run_meta_domain(results, dry_run)
        results
      end

      def report(results, dry_run:)
        puts "== results (#{dry_run ? "DRY RUN — nothing written" : "applied"}) =="
        puts "clean (no candidates): #{results[:clean].join(", ")}" unless results[:clean].empty?
        results[:applied].each { |r| puts "APPLIED  #{r[:file]}: #{r[:candidates].join(", ")}" }
        results[:skipped].each { |r| puts skipped_line(r) }
      end

      private

      def skipped_line(entry)
        "SKIPPED  #{entry[:file]} (#{entry[:reason]}): #{Array(entry[:candidates]).join(", ")}"
      end

      def run_example_domains(results, dry_run)
        Codemod::EXAMPLE_ROOTS.each { |domain_dir| run_example_domain(domain_dir, results, dry_run) }
      end

      def run_example_domain(domain_dir, results, dry_run)
        files = Dir.glob(File.join(domain_dir, "bluebook", "*.bluebook"))
        return if files.empty?

        before = Codemod.export_json(Codemod.load_bluebook(files))
        candidates = @find_candidates.call(Codemod.load_bluebook(files))
        return results[:clean] << domain_dir if candidates.empty?

        Sweep.new(self, example_setup(domain_dir, files, before), results, dry_run).call(candidates)
      end

      def example_setup(domain_dir, files, before)
        Sweep::Setup.new(
          files: files, before: before, no_match_file: domain_dir, failure_file: ->(target) { target },
          reboot: -> { Codemod.export_json(Codemod.load_bluebook(files)) }, stage_files: ->(target) { [target] },
          reason: lambda { |error|
            error ? "reboot raised after edit (#{error}) — reverted" : "IR changed after edit — reverted"
          }
        )
      end

      # Per-candidate, not batched — the meta-domain is one shared,
      # self-dispatching registry (S14), so a single unsafe candidate could
      # otherwise sink every other, genuinely safe one in the same run.
      def run_meta_domain(results, dry_run)
        before = Codemod.boot_meta
        candidates = @find_candidates.call(Codemod.meta_registry)
        return results[:clean] << "meta-domain" if candidates.empty?

        Sweep.new(self, meta_setup(before), results, dry_run).call(candidates)
      end

      # A dry run stages the text in memory and reboots from it, then drops it — so the next
      # candidate is judged against the true original state and no file is written.
      def meta_setup(before)
        Sweep::Setup.new(
          files: Codemod::META_FILES, before: before, no_match_file: "meta-domain",
          failure_file: ->(_target) { "meta-domain" }, reboot: -> { Codemod.boot_meta },
          stage_files: ->(_target) { Codemod::META_FILES },
          reason: ->(error) { error ? "reboot raised (#{error})" : "IR changed" }
        )
      end
    end
  end
end
