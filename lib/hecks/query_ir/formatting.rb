module Hecks
  module QueryIR
    # The text renderings of the diffs, previews and duplicate groups, shared by `hecks
    # ir_constructs` and `hecks serve_query_ir_mcp`. Extended onto `QueryIR`.
    module Formatting
      # The line saying a construct's diff is empty.
      CLEAN = "  clean — every declared field is emitted (or a named deviation), nothing emitted is undeclared".freeze

      # Renders `constructs` output as text, shared by `hecks ir_constructs` and `hecks
      # serve_query_ir_mcp`.
      #
      # @param diffs [Array<Hash>] `constructs`' own output
      # @return [String] the human-readable rendering
      def format_constructs(diffs)
        diffs.map { |diff| format_construct(diff) }.join("\n\n")
      end

      # Renders one field's touchpoint checklist as text.
      #
      # @param preview [Hash] `impact_preview`'s own output
      # @return [String] the human-readable rendering
      def format_impact_preview(preview)
        touchpoints = preview[:touchpoints]
        lines = ["== #{preview[:name]}##{preview[:field]} =="] +
                touchpoints.map { |t| "  [#{touchpoint_mark(t[:present]).rjust(7)}] #{t[:touchpoint]}" }
        (lines + ["", advisory(touchpoints)]).join("\n")
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

      private

      def format_construct(diff)
        lines = ["== #{diff[:name]} =="]
        lines << "  emits:    #{diff[:emitted].join(", ")}"
        lines << "  declares: #{diff[:declared].join(", ")}"
        lines.concat(construct_verdict(diff))
        lines.join("\n")
      end

      # @return [Array<String>] the lines saying what is missing or unaccounted, or that it is clean
      def construct_verdict(diff)
        missing = diff[:missing_from_ruby]
        unaccounted = diff[:unaccounted_in_ruby]
        return [CLEAN] if missing.empty? && unaccounted.empty?

        [fields_line("MISSING FROM RUBY (declared, not emitted, not a named deviation)", missing),
         fields_line("UNACCOUNTED IN RUBY (emitted, not declared, not a named deviation)", unaccounted)].compact
      end

      # @return [String, nil] the label and its fields on one line; nil when there are none
      def fields_line(label, fields)
        "  #{label}: #{fields.join(", ")}" unless fields.empty?
      end

      # @param present [Boolean, nil] whether a touchpoint shows signs of the field; nil when it
      #   does not apply
      def touchpoint_mark(present)
        return "n/a" if present.nil?

        present ? "yes" : "NOT YET"
      end

      def advisory(touchpoints)
        done = touchpoints.count { |t| t[:present] == true }
        total = touchpoints.count { |t| !t[:present].nil? }
        "#{done}/#{total} applicable touchpoint(s) show signs of this field — advisory, not a gate; " \
          "a NOT YET can be a legitimate exemption (Deviations, GUARANTEED_BY_CONSTRUCTION, or a spec-only " \
          "META_DOMAIN_KNOWN_GAPS entry this module deliberately never reads)."
      end
    end
  end
end
