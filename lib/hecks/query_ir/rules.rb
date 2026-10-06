module Hecks
  module QueryIR
    # The given/ensures/invariant rules declared across a corpus, and which of them are duplicated.
    # Extended onto `QueryIR`.
    module Rules
      # Every given/ensures/invariant reachable from a booted registry, walked recursively.
      #
      # Object identity carries no signal: `MetaValidator.call` rebuilds the graph from flat rows,
      # so a bare `given("x")` reference and its block declaration are distinct objects by then.
      # @param registry [Runtime::Registry] the booted registry to walk
      # @param chapter_name [String, nil] one chapter to walk, every booted chapter when nil
      # @return [Array<Rule>]
      def collect_rules(registry, chapter_name = nil)
        chapters = chapter_name ? [registry.bluebook(chapter_name)] : registry.bluebooks.values
        chapters.flat_map { |chapter| chapter.aggregates.flat_map { |aggregate| aggregate_rules(aggregate) } }
      end

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
        all_rules = include_meta ? collect_rules(Codemod.meta_registry) : []
        all_rules += (domains || Codemod::EXAMPLE_ROOTS).flat_map { |domain_dir| domain_rules(domain_dir) }
        duplicate_groups(all_rules)
      end

      private

      # @return [Array<Rule>] the rules of a real example domain, none when it has no bluebooks
      def domain_rules(domain_dir)
        files = Dir.glob(File.join(domain_dir, "bluebook", "*.bluebook"))
        files.empty? ? [] : collect_rules(Codemod.load_bluebook(files))
      end

      def duplicate_groups(all_rules)
        all_rules.group_by { |r| [r.kind, r.description, r.canonical] }
                 .map { |key, rules| [key, rules, declaration_count(rules)] }
                 .select { |_, _, count| count > 1 }
                 .map do |(kind, description, canonical), rules, _|
          { kind: kind, description: description, canonical: canonical, locations: rules.map(&:location) }
        end
      end

      def aggregate_rules(aggregate)
        rules = []
        walk_construct_rules(aggregate, aggregate.hecks_name, rules)
        aggregate.value_objects.each do |vo|
          vo.invariants.each do |rule|
            rules << build_rule("invariant", rule, "#{aggregate.hecks_name}::#{vo.hecks_name} (declared)")
          end
        end
        rules
      end

      # Recursive walk behind `collect_rules`; appends to `rules` in place.
      def walk_construct_rules(construct, path, rules)
        declared_rules(construct).each { |kind, rule| rules << build_rule(kind, rule, "#{path} (declared)") }
        construct.commands.each { |command| command_rules(command, path, rules) }
        return unless construct.respond_to?(:entities)

        construct.entities.each do |piece|
          walk_construct_rules(piece, "#{path}.#{piece.hecks_name}", rules)
        end
      end

      # @return [Array<Array(String, Object)>] the construct's own preconditions as `given` and its
      #   invariants, each with the kind it is reported as
      def declared_rules(construct)
        givens = construct.respond_to?(:preconditions) ? construct.preconditions.map { |rule| ["given", rule] } : []
        invariants = construct.respond_to?(:invariants) ? construct.invariants.map { |rule| ["invariant", rule] } : []
        givens + invariants
      end

      def command_rules(command, path, rules)
        location = "#{path}.#{command.hecks_name}"
        command.givens.each { |rule| rules << build_rule("given", rule, location) }
        command.ensures.each { |rule| rules << build_rule("ensures", rule, location) }
      end

      def build_rule(kind, rule, location)
        Rule.new(kind: kind, description: rule.description, canonical: rule.canonical, location: location)
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
        declared_given_roots = given_roots(declared)

        declared_owners.size + rules.count { |rule| !covered?(rule, declared_owners, declared_given_roots) }
      end

      # @return [Set<String>] the root aggregates owning a "(declared)" `given`
      def given_roots(declared)
        declared.select { |r| r.kind == "given" }.to_set { |r| owner_of(r.location).split(".").first }
      end

      # @return [Boolean] whether a "(declared)" entry already accounts for the rule
      def covered?(rule, declared_owners, declared_given_roots)
        owner = owner_of(rule.location)
        return true if declared_owners.include?(owner)

        rule.kind == "given" && owner.include?(".") && declared_given_roots.include?(owner.split(".").first)
      end
    end
  end
end
