# frozen_string_literal: true

module Hecks
  # The grep-based gate that keeps the query engines agreeing on what a comparator means.
  #
  # It fails when an engine re-grows its own comparator dispatch, or when a declared comparator
  # lacks a shared `Comparison` case or a cross-engine agreement spec. Every declared comparator
  # is read from `Hecks::Vocabulary`, as `Common::COMPARATORS` is: one live source, no copied list.
  module EngineAgreement
    # The engine files that must route every comparator through `Comparison.holds?`.
    ENGINE_FILES = {
      "in-memory port (Memory/Heki-backed aggregate queries)"                    => "lib/hecks/ports/query/in_memory.rb",
      "reference interpreter (entity/sub-list queries, no-native-hook fallback)" => "lib/hecks/runtime/query_interpreter.rb"
    }.freeze

    # Where the shared comparison logic lives.
    SHARED_COMPARISON_FILE = "lib/hecks/query_specification/common/comparison.rb"

    # Specs that put each comparator in front of both engines. `none_in_state` needs a second
    # aggregate and a registry, so the two dedicated growth specs cover it instead.
    AGREEMENT_SPEC_FILES = %w[
      spec/adapters/query_agreement_spec.rb
      spec/query_none_in_state_aggregate_level_growth_spec.rb
      spec/query_none_in_state_growth_spec.rb
    ].freeze

    # What a check found.
    #
    # @!attribute [r] declared
    #   @return [Array<String>] the comparators the vocabulary declares
    # @!attribute [r] problems
    #   @return [Array<String>] each disagreement, in words; empty when the engines agree
    Finding = Struct.new(:declared, :problems)

    module_function

    # Checks the engines against the vocabulary.
    #
    # @param root [String] the checkout whose files are read
    # @return [Finding] the declared comparators and every problem found
    def check(root:)
      require "hecks"
      declared = Hecks::Vocabulary.symbols("QueryComparator").map(&:to_s)
      if declared.empty?
        return Finding.new(declared, ["Vocabulary::QueryComparator declared no comparators at all — " \
                                      "vocabulary.bluebook failed to register, or Hecks::Vocabulary changed " \
                                      "shape. Refusing to report a clean pass."])
      end

      problems = vocabulary_problems(declared) + engine_problems(root, declared) + shared_problems(root, declared)
      Finding.new(declared, problems)
    end

    # @param declared [Array<String>] the declared comparators
    # @return [Array<String>] a problem when the language and the runtime table disagree
    def vocabulary_problems(declared)
      runtime = Hecks::QuerySpecification::Common::COMPARATORS.map(&:to_s)
      differ = (declared - runtime) | (runtime - declared)
      return [] if differ.empty?

      ["Vocabulary::QueryComparator #{declared.sort.inspect} and " \
       "QuerySpecification::Common::COMPARATORS #{runtime.sort.inspect} disagree " \
       "(only in one: #{differ.sort.inspect}) — the language and the runtime table it drives " \
       "have drifted apart."]
    end

    # @param root [String] the checkout
    # @param declared [Array<String>] the declared comparators
    # @return [Array<String>] a problem for each engine that lost `Comparison.holds?` or grew a case
    def engine_problems(root, declared)
      ENGINE_FILES.flat_map do |label, relative|
        source = File.read(File.join(root, relative))
        found = []
        unless source =~ /Comparison\.holds\?/
          found << "#{relative} (#{label}) no longer calls Comparison.holds? at all — " \
                   "has it grown its own comparator dispatch again?"
        end
        declared.each do |comparator|
          escaped = Regexp.escape(comparator)
          next unless source =~ /when\s+"#{escaped}"/ || source =~ /when\s+:#{escaped}\b/

          found << "#{relative} (#{label}) has its own `when #{comparator.inspect}` — comparator logic " \
                   "belongs ONLY in #{SHARED_COMPARISON_FILE}, not re-implemented per engine."
        end
        found
      end
    end

    # @param root [String] the checkout
    # @param declared [Array<String>] the declared comparators
    # @return [Array<String>] a problem for a comparator with no shared case, or no agreement spec
    def shared_problems(root, declared)
      comparison = File.read(File.join(root, SHARED_COMPARISON_FILE))
      specs = AGREEMENT_SPEC_FILES.map { |path| File.read(File.join(root, path)) }
      missing_case = declared.reject { |comparator| comparison =~ /when\s+"#{Regexp.escape(comparator)}"/ }
      missing_spec = declared.reject { |comparator| specs.any? { |text| mentions_operator?(text, comparator) } }

      [missing_case_problem(missing_case), missing_spec_problem(missing_spec)].compact
    end

    # @param missing [Array<String>] comparators with no `when` case in the shared file
    # @return [String, nil] the problem, or nil when none is missing
    def missing_case_problem(missing)
      return nil if missing.empty?

      "#{SHARED_COMPARISON_FILE} has no `when` case for: #{missing.sort.inspect} — " \
        "a declared comparator with no shared implementation falls to Comparison.holds?'s own `else`, " \
        "which RAISES (by design), but only the first time anything actually asks for it at runtime. " \
        "Add a `when #{missing.first.inspect} then ...` case before shipping this comparator."
    end

    # @param missing [Array<String>] comparators no agreement spec exercises
    # @return [String, nil] the problem, or nil when none is missing
    def missing_spec_problem(missing)
      return nil if missing.empty?

      "no example in #{AGREEMENT_SPEC_FILES.inspect} exercises: #{missing.sort.inspect} — " \
        "a comparator with a case but no cross-engine spec has never actually had both engines asked " \
        "the same question. Add a declared query using it, with a hand-computed expected id list, to one " \
        "of those files (see spec/adapters/query_agreement_spec.rb's own header for why a hand-computed " \
        "oracle, not mere pairwise agreement, is the standard)."
    end

    # @param text [String] a spec's source
    # @param comparator [String] the comparator name, such as `"eq"`
    # @return [Boolean] whether the spec puts the comparator in front of an engine
    def mentions_operator?(text, comparator)
      # Explicit form: the comparator as a bare hash key, bounded so `in:` cannot match
      # mid-identifier.
      return true if text =~ /(?<![A-Za-z0-9_])#{Regexp.escape(comparator)}(?![A-Za-z0-9_])\s*:/

      # `eq` is normally implicit (`where(status: "open")`), so an example description naming it
      # counts; no other comparator gets that leniency.
      return false unless comparator == "eq"

      text =~ /\b(?:it|describe)\s+"[^"]*\beq\b[^"]*"/i ? true : false
    end

    # @param finding [Finding] what a check found
    # @return [String] the clean-pass line
    def clean_line(finding)
      "check_engine_agreement: #{finding.declared.size} declared comparator(s) " \
        "(#{finding.declared.sort.join(', ')}) — every one has a shared Comparison case, a cross-engine " \
        "agreement spec, and both engine files still route through Comparison.holds? alone. 0 problems."
    end

    # @param finding [Finding] what a check found
    # @return [String] every problem, numbered, with where the mechanism is explained
    def problem_lines(finding)
      numbered = finding.problems.each_with_index.map { |problem, index| "  #{index + 1}. #{problem}\n\n" }
      ["check_engine_agreement: #{finding.problems.size} problem(s) found:\n\n", *numbered,
       "See lib/hecks/query_specification/common/comparison.rb's own header for what this mechanism " \
       "replaced and why a grep-based gate exists here at all."].join
    end
  end
end
