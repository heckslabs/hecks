module Hecks
  module QueryIR
    # The propagation touchpoints of a construct/field pair, checked in prose and in code. Extended
    # onto `QueryIR`.
    module Touchpoints
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
        CONSTRUCTS.fetch(name) { raise ArgumentError, "no such construct #{name.inspect} — known: #{CONSTRUCTS.keys.join(", ")}" }
        field = field.to_s
        { name: name, field: field, touchpoints: touchpoints(name, field) }
      end

      private

      def touchpoints(name, field)
        [
          { touchpoint: "meta-domain grammar declares it", present: meta_declared(name).map(&:to_s).include?(field) },
          { touchpoint: "docs/resolution-rules/ names it", present: resolution_rule_mentions?(field) },
          { touchpoint: "Assembly::Contracts consumes it", present: contract_consumes?(name, field) },
          { touchpoint: "Reconstruction's hand-typed method reads it", present: reconstruction_reads?(name, field) },
          { touchpoint: "fuzzer FEATURE_COVERAGE/GUARANTEED_BY_CONSTRUCTION claims it", present: fuzzer_claims?(name, field) },
          { touchpoint: "Rust mirror (rust/parser/src/parse/*.rs) mentions it", present: rust_mentions?(field) }
        ]
      end

      def resolution_rule_mentions?(field)
        paths = Dir.glob(File.join(Codemod::ROOT, "docs/resolution-rules/*.md")) +
                Dir.glob(File.join(Codemod::ROOT, "docs/implemented/resolution-rules/*.md"))
        paths.any? { |path| File.read(path).include?(field) }
      end

      def contract_consumes?(name, field)
        contract = Hecks::Bluebook::Assembly.contract(name)
        contract.fields.key?(field.to_sym) || contract.derived.key?(field.to_sym)
      rescue KeyError
        false
      end

      # nil, not false, for constructs without a hand-typed method: the touchpoint does not apply.
      def reconstruction_reads?(name, field)
        method_name = RECONSTRUCTION_METHODS[name]
        # rubocop:disable-next Style/ReturnNilInPredicateMethodDefinition -- nil vs
        # false is a deliberate distinction here: nil means "not applicable" (no
        # hand-typed method to check), false means "applicable, and it fails" —
        # see the spec's own "not-applicable (nil), not false" example.
        return nil unless method_name

        reconstruction_body(method_name).include?("#{field}:")
      end

      # @return [String] the source of one hand-typed `Reconstruction` method and of the helpers it
      #   delegates to, which are named `<method>_*`
      def reconstruction_body(method_name)
        reconstruction_method_names(method_name).map { |name| reconstruction_method_source(name) }.join
      end

      # @return [Array<Symbol>] `method_name` followed by its `<method_name>_*` helpers
      def reconstruction_method_names(method_name)
        reconstruction = Hecks::Bluebook::MetaValidator::Reconstruction
        helpers = reconstruction.instance_methods + reconstruction.private_instance_methods
        [method_name, *helpers.select { |name| name.to_s.start_with?("#{method_name}_") }.sort]
      end

      # @return [String] the source of one `Reconstruction` method
      def reconstruction_method_source(method_name)
        file, start_line = Hecks::Bluebook::MetaValidator::Reconstruction.instance_method(method_name).source_location
        lines = File.readlines(file)
        indent = lines[start_line - 1][/\A\s*/]

        lines[start_line..].take_while { |line| inside_method?(line, indent) }.join
      end

      # @param indent [String] the whitespace the method's `def` line starts with
      # @return [Boolean] whether the line still belongs to the method: blank, indented deeper, or
      #   not the next `def`
      def inside_method?(line, indent)
        line.strip.empty? || line[/\A\s*/].size > indent.size || !line.lstrip.start_with?("def ")
      end

      def fuzzer_claims?(name, field)
        key = "#{name}##{field}"
        Hecks::Fuzzing::Properties::FEATURE_COVERAGE.values.flatten.include?(key) ||
          Hecks::Fuzzing::Properties::GUARANTEED_BY_CONSTRUCTION.key?(key)
      end

      def rust_mentions?(field)
        Dir.glob(File.join(Codemod::ROOT, "rust/parser/src/parse/*.rs")).any? { |path| File.read(path).include?(field) }
      end
    end
  end
end
