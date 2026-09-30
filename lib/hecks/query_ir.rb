require_relative "bluebook"
require_relative "codemod"
require_relative "projections/model"
require_relative "fuzzing/properties"

module Hecks
  # Shared core of `hecks ir_constructs` and `hecks serve_query_ir_mcp`.
  # Returns structured data; formatting belongs to each front end.
  module QueryIR
    Codemod    = Hecks::Codemod
    Deviations = Hecks::Projections::Model::Deviations

    # Mirrors the conformance spec's MODEL_CONSTRUCTS; kept here because a spec is not a library.
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

    # Reads the fields the language declares for one construct kind, from the grammar itself.
    #
    # @param name [String] a `CONSTRUCTS` key, such as `"Aggregate"`
    # @return [Array<Symbol>] the attribute names the self-hosted meta-domain
    #   grammar declares for `name`
    def meta_declared(name)
      Hecks::Bluebook::MetaValidator.grammar_registry
                                    .bluebook("Bluebook").aggregate(name).attributes.map(&:name)
    end

    # The structural diff between what a Ruby IR class emits (`ir_spec.keys`) and what the
    # self-hosted meta-domain declares, using the `Deviations` data the conformance spec reads.
    # @param name [String] a `CONSTRUCTS` key, such as `"Aggregate"`
    # @return [Hash{Symbol => Object}] `:name`, `:declared`, `:emitted`, plus
    #   `:missing_from_ruby` and `:unaccounted_in_ruby` — each an `Array<Symbol>`
    # @raise [ArgumentError] if `name` is not a `CONSTRUCTS` key
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

    # Diffs one or every construct kind at once.
    #
    # @param names [Array<String>] `CONSTRUCTS` keys to diff, every construct when empty
    # @return [Array<Hash>] one `construct_diff` result per name
    def constructs(names = [])
      targets = names.empty? ? CONSTRUCTS.keys : names
      targets.map { |name| construct_diff(name) }
    end

    # Every given/ensures/invariant reachable from a booted registry, walked recursively.
    #
    # Object identity carries no signal: `MetaValidator.call` rebuilds the graph from flat rows,
    # so a bare `given("x")` reference and its block declaration are distinct objects by then.
    # @param registry [Runtime::Registry] the booted registry to walk
    # @param chapter_name [String, nil] one chapter to walk, every booted chapter when nil
    # @return [Array<Rule>]
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

    # Recursive walk behind `collect_rules`; appends to `rules` in place.
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

    # A rule's owner: the path a "(declared)" location names, or a command-level location
    # with its trailing `.CommandName` stripped.
    #
    # @param location [String] a `Rule#location`
    # @return [String] the owning construct's path, with `" (declared)"` or a trailing
    #   `.CommandName` segment stripped
    def owner_of(location)
      return location.sub(/ \(declared\)\z/, "") if location.end_with?(" (declared)")

      location.rpartition(".").first
    end

    # Groups rules by (kind, description, canonical) and reports groups with more than one
    # real declaration, counted by owner rather than object identity (see `collect_rules`).
    #
    # `domains: []` scans the self-hosted meta-domain only; `nil` adds every real example.
    # @param domains [Array<String>, nil] domain root directories to scan; every real
    #   example (`Codemod::EXAMPLE_ROOTS`) when nil, none beyond the meta-domain when `[]`
    # @param include_meta [Boolean] whether to also scan the self-hosted meta-domain
    # @return [Array<Hash>] one entry per duplicate group: `:kind`, `:description`,
    #   `:canonical`, and `:locations` (`Array<String>`)
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

    # A rule owned by a nested entity is also covered by a "(declared)" entry anywhere under the
    # same root aggregate, matching the DSL's shared given pool.
    #
    # Known gap: a bare chapter-wide `given(desc)` reference still shows as its own "(declared)"
    # owner, because the built IR cannot tell a reference from a declaration. Verify a flagged
    # group by hand before treating it as fresh duplication.
    # @param rules [Array<Rule>] one duplicate-key group's own rules
    # @return [Integer] how many of `rules` are real, independent declarations
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

    # Renders `constructs` output as text, shared by `hecks ir_constructs` and `hecks
    # serve_query_ir_mcp`.
    #
    # @param diffs [Array<Hash>] `constructs`' own output
    # @return [String] the human-readable rendering
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

    # The two `MetaValidator::Reconstruction` methods written by hand rather than driven by
    # `Assembly::Contracts`; `impact_preview` checks touchpoint 4 only for these.
    RECONSTRUCTION_METHODS = { "Aggregate" => :aggregate, "Entity" => :entity }.freeze

    # Checks the six touchpoints of `.claude/skills/bluebook-construct-creator/SKILL.md` for a
    # construct/field pair. Advisory, not a gate: a `false` can be a legitimate exemption
    # (`Deviations`, `GUARANTEED_BY_CONSTRUCTION`, or the spec-only `META_DOMAIN_KNOWN_GAPS`).
    #
    # @param name [String] a `CONSTRUCTS` key, such as `"Aggregate"`
    # @param field [String, Symbol] the declared field to check propagation for
    # @return [Hash{Symbol => Object}] `:name`, `:field`, and `:touchpoints` — an
    #   `Array<Hash>` of `:touchpoint` (String) and `:present` (Boolean, or nil when the
    #   touchpoint does not apply to `name`)
    # @raise [ArgumentError] if `name` is not a `CONSTRUCTS` key
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

    # nil, not false, for constructs without a hand-typed method: the touchpoint does not apply.
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

    # Renders one field's touchpoint checklist as text.
    #
    # @param preview [Hash] `impact_preview`'s own output
    # @return [String] the human-readable rendering
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

    # Renders the duplicate-rule groups as text.
    #
    # @param groups [Array<Hash>] `duplicates`' own output
    # @return [String] the human-readable rendering
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
