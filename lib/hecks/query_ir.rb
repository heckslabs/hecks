require_relative "bluebook"
require_relative "codemod"
require_relative "projections/model"
require_relative "fuzzing/properties"

module Hecks
  # The shared core behind `bin/query_ir` (a text CLI) and
  # `bin/hecks_query_ir_mcp` (an MCP server exposing the same two
  # queries as tools) — one implementation, two front ends, the same
  # reason `Hecks::Codemod` exists once rather than per-script.
  # Every method here returns structured data (Hashes/Arrays/Structs),
  # never formatted text — formatting is each front end's own job.
  module QueryIR
    Codemod    = Hecks::Codemod
    Deviations = Hecks::Projections::Model::Deviations

    # The same mapping spec/model_shape_conformance_spec.rb's own
    # MODEL_CONSTRUCTS holds — kept here rather than shared from the
    # spec (a spec file is not a library other code should require),
    # matching Deviations' own doc comment: "the generator and the gate
    # read one source" — Deviations is that one source; this table is
    # small and genuinely construct-list bookkeeping, not a rule that
    # can drift silently the way a Deviations entry could.
    CONSTRUCTS = {
      "Bluebook"       => Hecks::Bluebook::Chapter,
      "Aggregate"      => Hecks::Bluebook::Aggregate,
      "Command"        => Hecks::Bluebook::Command,
      "Entity"         => Hecks::Bluebook::Entity,
      "ValueObject"    => Hecks::Bluebook::ValueObject,
      "Policy"         => Hecks::Bluebook::Policy,
      "Query"          => Hecks::Bluebook::Query,
      "ReadModel"      => Hecks::Bluebook::ReadModel,
      "ProcessManager" => Hecks::Bluebook::ProcessManager
    }.freeze

    Rule = Struct.new(:kind, :description, :canonical, :location, keyword_init: true)

    module_function

    def meta_declared(name)
      Hecks::Bluebook::MetaValidator.grammar_registry
                                    .bluebook("Bluebook").aggregate(name).attributes.map(&:name)
    end

    # The real structural diff between what a Ruby IR class emits
    # (Class.ir_spec.keys) and what the self-hosted meta-domain declares
    # for it — the same comparison spec/model_shape_conformance_spec.rb
    # makes, reusing its own Deviations data so this can never silently
    # drift from what that gate actually checks.
    def construct_diff(name)
      klass = CONSTRUCTS.fetch(name) do
        raise ArgumentError, "no such construct #{name.inspect} — known: #{CONSTRUCTS.keys.join(', ')}"
      end
      declared = meta_declared(name)
      emitted  = klass.ir_spec.keys

      accounted = declared.reject { |field| Deviations.parent_ref?(field) } -
                  Deviations.judge_only(name) -
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

    # Every given/ensures/invariant declaration reachable from a booted
    # registry, walked recursively — every owner's own `.preconditions`/
    # `.invariants` (block-declared rules), every value object's own
    # `.invariants`, and every command's own `.givens`/`.ensures`
    # (`.givens` too, not just `.ensures` — a command's own local
    # `given("x") { block }` not yet hoisted to its owner, round 4's own
    # starting shape, would otherwise be invisible).
    #
    # Not keyed by object identity (a real, hard-won correction — see
    # the comment on `duplicates`' own dedup below for why: a bare
    # `given("x")` reference and its owner's own block declaration are
    # the same Ruby object at DSL build time, but `MetaValidator.call`
    # (S14 — every bluebook is judged by dispatching its own IR into the
    # self-hosted grammar, then reconstructed via `Assembly.call` from
    # flat rows) rebuilds the whole graph fresh from there. By the time
    # any caller reads `chapter.aggregates`, every given/invariant is
    # already a distinct object, whether it was block-declared or
    # bare-referenced — object identity carries no signal past that
    # point, for any construct, not just this one).
    def collect_rules(registry, chapter_name = nil)
      rules = []
      chapters = chapter_name ? [registry.bluebook(chapter_name)] : registry.bluebooks.values

      chapters.each do |chapter|
        chapter.aggregates.each do |aggregate|
          walk_construct_rules(aggregate, aggregate.hecks_name, rules)
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

    # The recursive walk `collect_rules` drives — pulled out of that method
    # (pure extraction, identical traversal and Rule shapes) as its own
    # named, self-recursive method rather than a lambda closing over the
    # same locals. `rules` is the one piece of state every call shares —
    # threaded as a parameter and mutated in place, the same accumulator
    # role the lambda's own closure played.
    def walk_construct_rules(construct, path, rules)
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
      return unless construct.respond_to?(:entities)

      construct.entities.each do |piece|
        walk_construct_rules(piece, "#{path}.#{piece.hecks_name}", rules)
      end
    end
    private_class_method :walk_construct_rules

    # A rule's owner — the construct path a "(declared)" location names
    # directly, or (for a command-level `.givens`/`.ensures` entry) the
    # path with its trailing `.CommandName` segment stripped. Two rules
    # sharing an owner are the same declaration read twice (an owner's
    # own precondition, and a command under it referencing that
    # precondition by name) — not two independent ones.
    #
    # Public, not a `duplicates`-only internal — `bin/codemod_hoist_
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
    # the same rule (same description, same predicate), which is also
    # exactly what the given/invariant reference mechanism itself
    # resolves on.
    #
    # Deduped by owner, not object identity (`collect_rules`' own
    # comment has the full story — identity is gone by the time this
    # reads the registry). Within a group, every command-level rule
    # whose owner already has its own "(declared)" entry in the same
    # group is just that declaration read again through a reference —
    # `Account.Open`/`Account.Credit`/etc. all naming `Account`'s own
    # `given("customer is active")` count as Account's one declaration,
    # not nine. A command-level rule with no matching owner declaration
    # (a local, not-yet-hoisted `given("x") { block }`) counts as its
    # own standalone declaration — two different commands independently
    # writing the identical local predicate is two declarations, a real
    # hoisting opportunity. A group is reported only when it adds up to
    # more than one real declaration this way.
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

        registry = Codemod.load_bluebook(bluebook_files)
        all_rules.concat(collect_rules(registry))
      end

      all_rules.group_by { |r| [r.kind, r.description, r.canonical] }
               .map { |key, rules| [key, rules, declaration_count(rules)] }
               .select { |_, _, count| count > 1 }
               .map do |(kind, description, canonical), rules, _|
        { kind: kind, description: description, canonical: canonical,
      locations: rules.map(&:location) }
      end
    end

    # `given` only (not `invariant`/`ensures`) also covers cross-entity
    # coverage — one piece's own entity-level declaration, shared with
    # any other piece nested under the same root aggregate (real corpus
    # this closes: SafeDepositBox's own `Visit`/`KeyIssuance`, two
    # different pieces on one head). A rule owned by a nested entity
    # (its own owner path has more than one segment) is covered when
    # some "(declared)" entry exists anywhere under that same root
    # aggregate — not just under its own exact owner — matching the
    # DSL's own pool, threaded unchanged through an aggregate's whole
    # entity tree (`AggregateBuilder#entity`'s own comment).
    #
    # A known, accepted gap this does not (and structurally cannot)
    # close: chapter-wide given sharing (`AggregateBuilder#given`'s own
    # bare form, `docs/implemented/resolution-rules/chapter-given.md`) — `Account`,
    # `SafeDepositBox`, and `OnboardingCase` each still show as their
    # own "(declared)" owner here even after `SafeDepositBox`/
    # `OnboardingCase` were converted to bare chapter-wide references,
    # because a referenced given still write-throughs into its own
    # aggregate's `@named_givens` — the same reason `collect_rules`'
    # own top comment already gives for why object identity carries no
    # signal past a bluebook's own build: the exported IR cannot tell
    # "I declared this myself" apart from "I referenced someone else's
    # declaration," because by the time anything reads `chapter.
    # aggregates`, both look identical. Closing this would mean reading
    # source text (bare `given(desc)` vs. block `given(desc) { ... }`),
    # not the built IR this query is deliberately built on — a
    # different, source-level tool, not a fix to this one. Treat a
    # still-flagged group naming multiple aggregates as "verify by
    # hand whether this is already a chapter-wide reference before
    # assuming it's fresh duplication," not as an automatic signal
    # either way.
    #
    # The identical gap, one level down: chapter-wide entity-scoped
    # sharing (`EntityBuilder#given`'s own bare form,
    # `docs/implemented/resolution-rules/chapter-entity-given.md`) hits this same wall for
    # the same structural reason — `SafeDepositBox.Visit` still shows
    # as its own "(declared)" owner here even after becoming a bare
    # reference to `Account.LedgerEntry`'s declaration, because a piece
    # resolving a chapter-wide reference still write-throughs the
    # resolved `Given` into its own `@named_givens` (so its own
    # commands can read it back locally without a second hop). This is
    # not a new limitation this feature introduces — it is the exact
    # same IR-cannot-distinguish-declared-from-referenced fact, one
    # scope wider. `bin/query_ir duplicates` confirms this directly:
    # `Account.LedgerEntry (declared)` and `SafeDepositBox.Visit
    # (declared)` both appear under the same `given: "customer is
    # active"` group — verify by hand, same as the aggregate-level
    # case above, before assuming a group naming two pieces under
    # different aggregates is fresh duplication rather than an already-
    # resolved chapter-wide reference.
    def declaration_count(rules)
      declared = rules.select { |r| r.location.end_with?(" (declared)") }
      declared_owners = declared.to_set { |r| owner_of(r.location) }
      declared_given_roots = declared.select { |r| r.kind == "given" }
                                     .to_set { |r| owner_of(r.location).split(".").first }

      standalone = rules.reject do |r|
        owner = owner_of(r.location)
        next true if declared_owners.include?(owner)
        next true if r.kind == "given" && owner.include?(".") && declared_given_roots.include?(owner.split(".").first)

        false
      end

      declared_owners.size + standalone.size
    end
    private_class_method :declaration_count

    # Shared text formatting — both `bin/query_ir` (a text CLI) and
    # `bin/hecks_query_ir_mcp` (an MCP tool result, itself a text
    # block) want the identical human-readable rendering; only the
    # outer framing differs (plain stdout vs. a JSON-RPC content array).
    def format_constructs(diffs)
      diffs.map do |diff|
        lines = ["== #{diff[:name]} =="]
        lines << "  emits:    #{diff[:emitted].join(', ')}"
        lines << "  declares: #{diff[:declared].join(', ')}"
        if diff[:missing_from_ruby].empty? && diff[:unaccounted_in_ruby].empty?
          lines << "  clean — every declared field is emitted (or a named deviation), nothing emitted is undeclared"
        else
          unless diff[:missing_from_ruby].empty?
            lines << "  MISSING FROM RUBY (declared, not emitted, not a named deviation): " \
                     "#{diff[:missing_from_ruby].join(', ')}"
          end
          unless diff[:unaccounted_in_ruby].empty?
            lines << "  UNACCOUNTED IN RUBY (emitted, not declared, not a named deviation): " \
                     "#{diff[:unaccounted_in_ruby].join(', ')}"
          end
        end
        lines.join("\n")
      end.join("\n\n")
    end

    # **One hand-typed construct-name per reconstruction method** — the only
    # two `MetaValidator::Reconstruction` methods not driven generically
    # through `Assembly::Contracts`' own table (its own header explains
    # why: `aggregate(row)`/`entity(row)` predate the table and were
    # never migrated). `impact_preview`'s own touchpoint 4 is checked
    # only for these two — every other construct is read generically, so
    # asking "does Command's own reconstruction method mention this
    # field" is a question with no method to check.
    RECONSTRUCTION_METHODS = { "Aggregate" => :aggregate, "Entity" => :entity }.freeze

    # The six touchpoints `.claude/skills/bluebook-construct-creator/
    # SKILL.md` walks in prose, checked structurally instead of by hand
    # — for a construct/field pair not yet fully propagated (typically
    # mid-round, deciding what's left), or as a sanity check before the
    # final gate sweep of a round already believed done. Every check
    # here is best-effort and advisory, not a gate: a `false` does not
    # always mean "not yet done" (a field can be legitimately exempt —
    # `Deviations`' own named categories, `GUARANTEED_BY_CONSTRUCTION`,
    # or `META_DOMAIN_KNOWN_GAPS`, the last of which lives in
    # spec/fuzzing/meta_domain_coverage_spec.rb, a spec file this
    # module deliberately never requires — see `CONSTRUCTS`' own
    # comment on the same principle). Read the touchpoint's own
    # existing gate (`model_shape_conformance_spec.rb`,
    # `assembly_spec.rb`, `meta_domain_coverage_spec.rb`) before trusting
    # a `false` here as a real gap.
    def impact_preview(name, field)
      CONSTRUCTS.fetch(name) { raise ArgumentError, "no such construct #{name.inspect} — known: #{CONSTRUCTS.keys.join(', ')}" }
      field = field.to_s

      {
        name:        name,
        field:       field,
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
      paths = Dir.glob(File.join(Codemod::ROOT, "docs/resolution-rules/*.md")) +
              Dir.glob(File.join(Codemod::ROOT, "docs/implemented/resolution-rules/*.md"))
      paths.any? { |path| File.read(path).include?(field) }
    end
    private_class_method :resolution_rule_mentions?

    def contract_consumes?(name, field)
      contract = Hecks::Bluebook::Assembly.contract(name)
      contract.fields.key?(field.to_sym) || contract.derived.key?(field.to_sym)
    rescue KeyError
      false
    end
    private_class_method :contract_consumes?

    # `Method#source_location` finds where the hand-typed method starts;
    # the method's own body ends at the next line indented no deeper
    # than its own `def` — the same boundary Ruby itself uses, read back
    # textually because there is no live AST here, only a file to grep a
    # slice of. `nil` (not `false`) for every other construct — this
    # touchpoint genuinely does not apply to them (`RECONSTRUCTION_
    # METHODS` only names the two hand-typed methods), and collapsing
    # "does not apply" into "not done" would misreport a construct that
    # was never supposed to have this touchpoint at all.
    def reconstruction_reads?(name, field)
      method_name = RECONSTRUCTION_METHODS[name]
      # rubocop:disable-next Style/ReturnNilInPredicateMethodDefinition -- nil vs
      # false is a deliberate distinction here: nil means "not applicable" (no
      # hand-typed method to check), false means "applicable, and it fails" —
      # see the spec's own "not-applicable (nil), not false" example.
      return nil unless method_name

      file, start_line = Hecks::Bluebook::MetaValidator::Reconstruction.instance_method(method_name).source_location
      lines = File.readlines(file)
      def_line = lines[start_line - 1]
      indent = def_line[/\A\s*/]

      body = lines[start_line..].take_while do |line|
        line.strip.empty? || line[/\A\s*/].size > indent.size || !line.lstrip.start_with?("def ")
      end
      body.join.include?("#{field}:")
    end
    private_class_method :reconstruction_reads?

    def fuzzer_claims?(name, field)
      key = "#{name}##{field}"
      Hecks::Fuzzing::Properties::FEATURE_COVERAGE.values.flatten.include?(key) ||
        Hecks::Fuzzing::Properties::GUARANTEED_BY_CONSTRUCTION.key?(key)
    end
    private_class_method :fuzzer_claims?

    def rust_mentions?(field)
      Dir.glob(File.join(Codemod::ROOT, "rust/parser/src/parse/*.rs")).any? { |path| File.read(path).include?(field) }
    end
    private_class_method :rust_mentions?

    def format_impact_preview(preview)
      lines = ["== #{preview[:name]}##{preview[:field]} =="]
      preview[:touchpoints].each do |t|
        mark = if t[:present].nil?
                 "n/a"
               else
                 (t[:present] ? "yes" : "NOT YET")
               end
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
