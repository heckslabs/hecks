        validator = by_aggregate("DiagnosticValidator").first
        helpers = by_aggregate("DiagnosticHelper")
                    .select { |h| h["attrs"]["validator"] == validator["attrs"]["module"] }
                    .sort_by { |h| h["attrs"]["order"].to_i }
        helpers_first = validator["attrs"]["helpers_after_rule"] != "true"
        parts = [emit_header(validator), emit_imports(validator), emit_report(validator["attrs"]["report_kind"])]
        if helpers_first
          # duplicate_policy style: Report → helpers → rule (rule last, no trailing blank)
          parts << helpers.map { |h| emit_helper(h) }.join
          parts << emit_rule(validator, leading_blank: true)
        else
          # lifecycle/io style: Report → rule → helpers (last helper no trailing blank)
          parts << emit_rule(validator, leading_blank: false, trailing_blank: true)
          helpers.each_with_index do |h, i|
            parts << emit_helper(h, trailing_blank: i < helpers.size - 1)
          end
        end
        parts.join
