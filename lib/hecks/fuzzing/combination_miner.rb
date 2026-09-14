require "json"
require "open3"
require_relative "form_census"

module Hecks
  module Fuzzing
    # AN AGENT READS THE ADVERSARIAL CORPUS AND WRITES THE NEXT MEETING.
    #
    # `DomainGenerator` forces two `FormCensus::FORMS` onto one aggregate
    # from a seed — cheap, mechanical, and blind to WHY a combination
    # should break. The bugs the ledger actually logged came from someone
    # reading a stress domain, a bug title, and a runtime file side by
    # side and guessing where the next divergence lives (`corrections`
    # from BUG#30-33, `case_escalation` from ADR 0037 Finding 5 meeting
    # `corrects`). This is that guess, delegated: the mechanical half
    # (what the corpus already puts together, which pairs nothing meets,
    # what the recent bugs were) is computed here; the judgment half is a
    # prompt (`qa/combination_miner/prompt.md`) an agent answers by
    # WRITING candidate bluebooks, each with a hypothesis. Checking them
    # is not this module's job — `bin/qa_mine_combinations` hands every
    # valid candidate to `bin/qa_generated_domains --source`, the same
    # differential, self-consistency, Rust build and shrinking path a
    # generated domain takes.
    #
    # OPT-IN, NEVER THE ROTATION. An agent call costs money and minutes
    # and answers differently every time; `bin/qa_tick` never runs it and
    # no `QualityControlDials` entry turns it on. A person runs
    # `bin/qa_mine_combinations` when they want new shapes.
    module CombinationMiner
      PROMPT_TEMPLATE = "qa/combination_miner/prompt.md".freeze
      HYPOTHESIS_FILE = "HYPOTHESIS.md".freeze

      module_function

      # Every adversarial domain plus every example — the corpus the
      # census is measured over. Promoted generated domains are included:
      # their shapes are already swept too.
      def corpus_paths(root)
        Hecks::Corpus.members(:stress, :example, root: root).map(&:path)
                     .select { |path| Hecks::Corpus.bluebook_files(path) }
                     .sort
      end

      # The last `limit` bug commit subjects on this branch — cheap, needs
      # no ledger or Postgres, and names the mechanism in the title by
      # convention (`BUG#n: …`).
      def recent_bug_titles(root, limit: 60)
        out, status = Open3.capture2("git", "log", "--format=%s", "--grep=BUG#", "-n", limit.to_s, chdir: root)
        status.success? ? out.lines.map(&:strip).reject(&:empty?) : []
      end

      # The mechanical half: which form pairs the corpus meets (and by
      # whom), which it never meets, and what could not be measured.
      def brief(paths, root:, bug_titles:)
        covered = Hash.new { |hash, key| hash[key] = [] }
        skipped = []
        paths.each do |path|
          FormCensus.covered_pairs(FormCensus.census(path)).each { |pair, names| covered[pair].concat(names) }
        rescue StandardError, ScriptError => e
          skipped << "#{relative(path, root)} (#{e.class}: #{e.message.lines.first&.strip})"
        end
        { "forms" => FormCensus::FORMS.keys, "corpus" => paths.map { |path| relative(path, root) },
          "unmet_pairs" => (FormCensus.pairs - covered.keys).sort,
          "single_carrier_pairs" => covered.select { |_, names| names.uniq.size == 1 }
                                           .map { |pair, names| "#{pair} (only #{names.first})" }.sort,
          "skipped" => skipped, "recent_bugs" => bug_titles, "covered" => covered }
      end

      def prompt(root, brief, count:, out_dir:)
        substitutions = {
          "count" => count.to_s, "out_dir" => out_dir, "forms" => brief["forms"].join(", "),
          "corpus" => bulleted(brief["corpus"]), "unmet_pairs" => bulleted(brief["unmet_pairs"]),
          "single_carrier_pairs" => bulleted(brief["single_carrier_pairs"]),
          "recent_bugs" => bulleted(brief["recent_bugs"]), "skipped" => bulleted(brief["skipped"])
        }
        File.read(File.join(root, PROMPT_TEMPLATE)).gsub(/\{\{(\w+)\}\}/) { substitutions.fetch(Regexp.last_match(1)) }
      end

      # The second, narrower ask: these candidates did not boot, here is
      # why, fix them in place. Nothing else in the directory changes.
      def repair_prompt(failures, out_dir:)
        listed = failures.map { |candidate, error| "- #{candidate[:bluebook]}\n  boot error: #{error}" }.join("\n")
        <<~PROMPT
          REPAIR ROUND. You wrote candidate Hecks bluebooks under #{out_dir} for the QA combination miner.
          These did not boot. Edit each file IN PLACE so it boots, keeping the construct combination its
          #{HYPOTHESIS_FILE} names (update the hypothesis if the fix changes the shape). Do not create new
          candidates and do not touch anything outside #{out_dir}.

          #{listed}
        PROMPT
      end

      # `<out_dir>/<slug>/<anything>.bluebook` plus an optional
      # HYPOTHESIS.md beside it. One bluebook per candidate: the first,
      # alphabetically, if an agent wrote more.
      def candidates(out_dir)
        Dir[File.join(out_dir, "*")].select { |dir| File.directory?(dir) }.sort.filter_map do |dir|
          bluebook = Dir[File.join(dir, "*.bluebook")].min
          next unless bluebook

          hypothesis = File.join(dir, HYPOTHESIS_FILE)
          { slug: File.basename(dir), dir: dir, bluebook: bluebook,
            hypothesis: File.exist?(hypothesis) ? File.read(hypothesis).strip : nil }
        end
      end

      # Pairs the candidate meets on one aggregate that no corpus domain
      # does — informational, never a gate: an agent may be aiming at a
      # shape the census does not name yet.
      def new_pairs(candidate_dir, covered)
        FormCensus.covered_pairs(FormCensus.census(candidate_dir)).keys.reject { |pair| covered.key?(pair) }.sort
      end

      def relative(path, root) = path.delete_prefix("#{root}/")

      def bulleted(items) = items.empty? ? "(none)" : items.map { |item| "- #{item}" }.join("\n")
    end
  end
end
