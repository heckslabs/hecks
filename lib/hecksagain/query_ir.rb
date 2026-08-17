require "set"
require_relative "codemod"
require_relative "projections/model"
require_relative "fuzzing/properties"

module Hecksagain
  # THE SHARED CORE behind `bin/query_ir` (a text CLI) and
  # `bin/hecksagain_query_ir_mcp` (an MCP server exposing the same two
  # queries as tools) — one implementation, two front ends, the same
  # reason `Hecksagain::Codemod` exists once rather than per-script.
  # Every method here returns structured data (Hashes/Arrays/Structs),
  # never formatted text — formatting is each front end's own job.
  module QueryIR
    Codemod    = Hecksagain::Codemod
    Deviations = Hecksagain::Projections::Model::Deviations

    # THE SAME MAPPING spec/model_shape_conformance_spec.rb's own
    # MODEL_CONSTRUCTS holds — kept here rather than shared from the
    # spec (a spec file is not a library other code should require),
    # matching Deviations' own doc comment: "the generator and the gate
    # read one source" — Deviations is that one source; this table is
    # small and genuinely construct-list bookkeeping, not a rule that
    # can drift silently the way a Deviations entry could.
    CONSTRUCTS = {
      "Bluebook"       => Hecksagain::Bluebook::Chapter,
      "Aggregate"      => Hecksagain::Bluebook::Aggregate,
      "Command"        => Hecksagain::Bluebook::Command,
      "Entity"         => Hecksagain::Bluebook::Entity,
      "ValueObject"    => Hecksagain::Bluebook::ValueObject,
      "Policy"         => Hecksagain::Bluebook::Policy,
      "Query"          => Hecksagain::Bluebook::Query,
      "ReadModel"      => Hecksagain::Bluebook::ReadModel,
      "ProcessManager" => Hecksagain::Bluebook::ProcessManager
    }.freeze

    Rule = Struct.new(:kind, :description, :canonical, :location, keyword_init: true)

    module_function

    def meta_declared(name)
      Hecksagain::Bluebook::MetaValidator.grammar_registry
        .bluebook("Bluebook").aggregate(name).attributes.map(&:name)
    end

    # The real structural diff between what a Ruby IR class emits
    # (Class.ir_spec.keys) and what the self-hosted meta-domain declares
    # for it — the SAME comparison spec/model_shape_conformance_spec.rb
    # makes, reusing its own Deviations data so this can never silently
    # drift from what that gate actually checks.
    def construct_diff(name)
      klass = CONSTRUCTS.fetch(name) { raise ArgumentError, "no such construct #{name.inspect} — known: #{CONSTRUCTS.keys.join(', ')}" }
      declared = meta_declared(name)
      emitted  = klass.ir_spec.keys

      accounted = declared.reject { |field| Deviations::PARENT_REF.call(field) } -
                  Deviations::JUDGE_ONLY -
                  Deviations.folded(name).values.flatten -
                  Deviations.off_the_wire(name) -
                  Deviations.dynamic_tail(name) -
                  Deviations.unpacked(name).keys

      unaccounted = emitted -
                    declared -
                    Deviations.contained(name) -
                    Deviations.folded(name).keys -
                    Deviations.computed(name) -
                    Deviations.unpacked(name).values.flatten

      { name: name, declared: declared, emitted: emitted,
        missing_from_ruby: accounted - emitted, unaccounted_in_ruby: unaccounted }
    end

    def constructs(names = [])
      targets = names.empty? ? CONSTRUCTS.keys : names
      targets.map { |name| construct_diff(name) }
    end

    # Every given/ensures/invariant DECLARATION reachable from a booted
    # registry, walked recursively — every owner's own `.preconditions`/
    # `.invariants` (block-declared rules), every value object's own
    # `.invariants`, and every command's own `.givens`/`.ensures`
    # (`.givens` too, not just `.ensures` — a command's own LOCAL
    # `given("x") { block }` not yet hoisted to its owner, round 4's own
    # starting shape, would otherwise be invisible).
    #
    # NOT keyed by object identity (a real, hard-won correction — see
    # the comment on `duplicates`' own dedup below for why: a bare
    # `given("x")` reference and its owner's own block declaration are
    # the SAME Ruby object at DSL build time, but `MetaValidator.call`
    # (S14 — every bluebook is judged by dispatching its OWN IR into the
    # self-hosted grammar, then reconstructed via `Assembly.call` from
    # flat rows) rebuilds the whole graph fresh from there. By the time
    # any caller reads `chapter.aggregates`, EVERY given/invariant is
    # already a distinct object, whether it was block-declared or
    # bare-referenced — object identity carries no signal past that
    # point, for any construct, not just this one).
    def collect_rules(registry, chapter_name = nil)
      rules = []
      chapters = chapter_name ? [registry.bluebook(chapter_name)] : registry.bluebooks.values

      walk_construct = lambda do |construct, path|
        (construct.respond_to?(:preconditions) ? construct.preconditions : []).each do |rule|
          rules << Rule.new(kind: "given", description: rule.description, canonical: rule.canonical,
                             location: "#{path} (declared)")
        end
        (construct.respond_to?(:invariants) ? construct.invariants : []).each do |rule|
          rules << Rule.new(kind: "invariant", description: rule.description, canonical: rule.canonical,
                             location: "#{path} (declared)")
        end
        construct.commands.each do |command|
          command.givens.each do |rule|
            rules << Rule.new(kind: "given", description: rule.description, canonical: rule.canonical,
                               location: "#{path}.#{command.hecks_name}")
          end
          command.ensures.each do |rule|
            rules << Rule.new(kind: "ensures", description: rule.description, canonical: rule.canonical,
                               location: "#{path}.#{command.hecks_name}")
          end
        end
        construct.entities.each { |piece| walk_construct.call(piece, "#{path}.#{piece.hecks_name}") } if construct.respond_to?(:entities)
      end

      chapters.each do |chapter|
        chapter.aggregates.each do |aggregate|
          walk_construct.call(aggregate, aggregate.hecks_name)
          aggregate.value_objects.each do |vo|
            vo.invariants.each do |rule|
              rules << Rule.new(kind: "invariant", description: rule.description, canonical: rule.canonical,
                                 location: "#{aggregate.hecks_name}::#{vo.hecks_name} (declared)")
            end
          end
        end
      end
      rules
    end

    # A rule's OWNER — the construct path a "(declared)" location names
    # directly, or (for a command-level `.givens`/`.ensures` entry) the
    # path with its trailing `.CommandName` segment stripped. Two rules
    # sharing an owner are the SAME declaration read twice (an owner's
    # own precondition, and a command under it referencing that
    # precondition by name) — not two independent ones.
    #
    # PUBLIC, not a `duplicates`-only internal — `bin/codemod_hoist_
    # local_givens` reads it directly to group `collect_rules`' own
    # output by owner itself, the same reading `duplicates`' own
    # `declaration_count` makes.
    def owner_of(location)
      return location.sub(/ \(declared\)\z/, "") if location.end_with?(" (declared)")

      location.rpartition(".").first
    end

    # Grouped by (kind, description, canonical), not canonical text
    # alone — a generic one-liner like `!value.to_s.empty?` legitimately
    # recurs dozens of times for unrelated fields; the real signal is
    # the SAME RULE (same description, same predicate), which is also
    # exactly what the given/invariant reference mechanism itself
    # resolves on.
    #
    # DEDUPED BY OWNER, not object identity (`collect_rules`' own
    # comment has the full story — identity is gone by the time this
    # reads the registry). Within a group, every command-level rule
    # whose OWNER already has its own "(declared)" entry in the same
    # group is just that declaration read again through a reference —
    # `Account.Open`/`Account.Credit`/etc. all naming `Account`'s own
    # `given("customer is active")` count as Account's ONE declaration,
    # not nine. A command-level rule with no matching owner declaration
    # (a LOCAL, not-yet-hoisted `given("x") { block }`) counts as its
    # own standalone declaration — two different commands independently
    # writing the identical local predicate IS two declarations, a real
    # hoisting opportunity. A group is reported only when it adds up to
    # MORE than one real declaration this way.
    #
    # `domains: []` means "the self-hosted meta-domain only" — pass real
    # domain directories explicitly to include them, or `nil` (the
    # default) for meta-domain plus every real example.
    def duplicates(domains: nil, include_meta: true)
      domains ||= Codemod::EXAMPLE_ROOTS
      all_rules = []
      all_rules.concat(collect_rules(Codemod.meta_registry)) if include_meta

      domains.each do |domain_dir|
        bluebook_files = Dir.glob(File.join(domain_dir, "bluebook", "*.bluebook"))
        next if bluebook_files.empty?

        registry = Codemod.load_bluebook(bluebook_files.first)
        all_rules.concat(collect_rules(registry))
      end

      all_rules.group_by { |r| [r.kind, r.description, r.canonical] }
               .map { |key, rules| [key, rules, declaration_count(rules)] }
               .select { |_, _, count| count > 1 }
               .map { |(kind, description, canonical), rules, _| { kind: kind, description: description, canonical: canonical, locations: rules.map(&:location) } }
    end

    # `given` ONLY (not `invariant`/`ensures`) also covers CROSS-ENTITY
    # coverage — one piece's own entity-level declaration, shared with
    # any OTHER piece nested under the SAME root aggregate (real corpus
    # this closes: SafeDepositBox's own `Visit`/`KeyIssuance`, two
    # different pieces on one head). A rule owned by a nested entity
    # (its own owner path has more than one segment) is covered when
    # SOME "(declared)" entry exists ANYWHERE under that SAME root
    # aggregate — not just under its OWN exact owner — matching the
    # DSL's own pool, threaded unchanged through an aggregate's whole
    # entity tree (`AggregateBuilder#entity`'s own comment).
    def declaration_count(rules)
      declared = rules.select { |r| r.location.end_with?(" (declared)") }
      declared_owners = declared.map { |r| owner_of(r.location) }.to_set
      declared_given_roots = declared.select { |r| r.kind == "given" }
                                     .map { |r| owner_of(r.location).split(".").first }.to_set

      standalone = rules.reject do |r|
        owner = owner_of(r.location)
        next true if declared_owners.include?(owner)
        next true if r.kind == "given" && owner.include?(".") && declared_given_roots.include?(owner.split(".").first)

        false
      end

      declared_owners.size + standalone.size
    end
    private_class_method :declaration_count

    # SHARED TEXT FORMATTING — both `bin/query_ir` (a text CLI) and
    # `bin/hecksagain_query_ir_mcp` (an MCP tool result, itself a text
    # block) want the identical human-readable rendering; only the
    # OUTER framing differs (plain stdout vs. a JSON-RPC content array).
    def format_constructs(diffs)
      diffs.map do |diff|
        lines = ["== #{diff[:name]} =="]
        lines << "  emits:    #{diff[:emitted].join(', ')}"
        lines << "  declares: #{diff[:declared].join(', ')}"
        if diff[:missing_from_ruby].empty? && diff[:unaccounted_in_ruby].empty?
          lines << "  clean — every declared field is emitted (or a named deviation), nothing emitted is undeclared"
        else
          lines << "  MISSING FROM RUBY (declared, not emitted, not a named deviation): #{diff[:missing_from_ruby].join(', ')}" unless diff[:missing_from_ruby].empty?
          lines << "  UNACCOUNTED IN RUBY (emitted, not declared, not a named deviation): #{diff[:unaccounted_in_ruby].join(', ')}" unless diff[:unaccounted_in_ruby].empty?
        end
        lines.join("\n")
      end.join("\n\n")
    end

    # ONE HAND-TYPED CONSTRUCT-NAME PER RECONSTRUCTION METHOD — the only
    # two `MetaValidator::Reconstruction` methods NOT driven generically
    # through `Assembly::Contracts`' own table (its own header explains
    # why: `aggregate(row)`/`entity(row)` predate the table and were
    # never migrated). `impact_preview`'s own touchpoint 4 is checked
    # ONLY for these two — every other construct is read generically, so
    # asking "does Command's own reconstruction method mention this
    # field" is a question with no method to check.
    RECONSTRUCTION_METHODS = { "Aggregate" => :aggregate, "Entity" => :entity }.freeze

    # THE SIX TOUCHPOINTS `.claude/skills/bluebook-construct-creator/
    # SKILL.md` walks in prose, checked structurally instead of by hand
    # — for a construct/field pair NOT yet fully propagated (typically
    # mid-round, deciding what's left), or as a sanity check before the
    # final gate sweep of a round already believed done. Every check
    # here is BEST-EFFORT and ADVISORY, not a gate: a `false` does not
    # always mean "not yet done" (a field can be legitimately exempt —
    # `Deviations`' own named categories, `GUARANTEED_BY_CONSTRUCTION`,
    # or `META_DOMAIN_KNOWN_GAPS`, the last of which lives in
    # spec/fuzzing/meta_domain_coverage_spec.rb, a SPEC file this
    # module deliberately never requires — see `CONSTRUCTS`' own
    # comment on the same principle). Read the touchpoint's own
    # existing gate (`model_shape_conformance_spec.rb`,
    # `assembly_spec.rb`, `meta_domain_coverage_spec.rb`) before trusting
    # a `false` here as a real gap.
    def impact_preview(name, field)
      CONSTRUCTS.fetch(name) { raise ArgumentError, "no such construct #{name.inspect} — known: #{CONSTRUCTS.keys.join(', ')}" }
      field = field.to_s

      {
        name: name,
        field: field,
        touchpoints: [
          { touchpoint: "meta-domain grammar declares it", present: meta_declared(name).map(&:to_s).include?(field) },
          { touchpoint: "docs/resolution-rules/ names it", present: resolution_rule_mentions?(field) },
          { touchpoint: "Assembly::Contracts consumes it", present: contract_consumes?(name, field) },
          { touchpoint: "Reconstruction's hand-typed method reads it", present: reconstruction_reads?(name, field) },
          { touchpoint: "fuzzer FEATURE_COVERAGE/GUARANTEED_BY_CONSTRUCTION claims it", present: fuzzer_claims?(name, field) },
          { touchpoint: "Rust mirror (rust/parser/src/parse/*.rs) mentions it", present: rust_mentions?(field) }
        ]
      }
    end

    def resolution_rule_mentions?(field)
      Dir.glob(File.join(Codemod::ROOT, "docs/resolution-rules/*.md")).any? { |path| File.read(path).include?(field) }
    end
    private_class_method :resolution_rule_mentions?

    def contract_consumes?(name, field)
      contract = Hecksagain::Bluebook::Assembly.contract(name)
      contract.fields.key?(field.to_sym) || contract.derived.key?(field.to_sym)
    rescue KeyError
      false
    end
    private_class_method :contract_consumes?

    # `Method#source_location` finds where the hand-typed method starts;
    # the method's own body ends at the next line indented no deeper
    # than its own `def` — the same boundary Ruby itself uses, read back
    # textually because there is no live AST here, only a file to grep a
    # slice of. `nil` (not `false`) for every OTHER construct — this
    # touchpoint genuinely does not apply to them (`RECONSTRUCTION_
    # METHODS` only names the two hand-typed methods), and collapsing
    # "does not apply" into "not done" would misreport a construct that
    # was never supposed to have this touchpoint at all.
    def reconstruction_reads?(name, field)
      method_name = RECONSTRUCTION_METHODS[name]
      return nil unless method_name

      file, start_line = Hecksagain::Bluebook::MetaValidator::Reconstruction.instance_method(method_name).source_location
      lines = File.readlines(file)
      def_line = lines[start_line - 1]
      indent = def_line[/\A\s*/]

      body = lines[start_line..].take_while { |line| line.strip.empty? || line[/\A\s*/].size > indent.size || !line.lstrip.start_with?("def ") }
      body.join.include?("#{field}:")
    end
    private_class_method :reconstruction_reads?

    def fuzzer_claims?(name, field)
      key = "#{name}##{field}"
      Hecksagain::Fuzzing::Properties::FEATURE_COVERAGE.values.flatten.include?(key) ||
        Hecksagain::Fuzzing::Properties::GUARANTEED_BY_CONSTRUCTION.key?(key)
    end
    private_class_method :fuzzer_claims?

    def rust_mentions?(field)
      Dir.glob(File.join(Codemod::ROOT, "rust/parser/src/parse/*.rs")).any? { |path| File.read(path).include?(field) }
    end
    private_class_method :rust_mentions?

    def format_impact_preview(preview)
      lines = ["== #{preview[:name]}##{preview[:field]} =="]
      preview[:touchpoints].each do |t|
        mark = t[:present].nil? ? "n/a" : (t[:present] ? "yes" : "NOT YET")
        lines << "  [#{mark.rjust(7)}] #{t[:touchpoint]}"
      end
      done = preview[:touchpoints].count { |t| t[:present] == true }
      total = preview[:touchpoints].count { |t| !t[:present].nil? }
      lines << ""
      lines << "#{done}/#{total} applicable touchpoint(s) show signs of this field — advisory, not a gate; " \
               "a NOT YET can be a legitimate exemption (Deviations, GUARANTEED_BY_CONSTRUCTION, or a spec-only " \
               "META_DOMAIN_KNOWN_GAPS entry this module deliberately never reads)."
      lines.join("\n")
    end

    def format_duplicates(groups)
      return "no duplicate given/invariant/ensures rule found" if groups.empty?

      body = groups.map do |group|
        ["== #{group[:kind]}: #{group[:description].inspect} — #{group[:canonical]} ==",
         *group[:locations].map { |loc| "  #{loc}" }].join("\n")
      end.join("\n\n")

      "#{body}\n\n#{groups.size} duplicate group(s), #{groups.sum { |g| g[:locations].size }} declarations total"
    end
  end
end
