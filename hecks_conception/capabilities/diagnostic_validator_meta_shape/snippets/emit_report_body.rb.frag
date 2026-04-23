        case kind
        when "flat"                    then emit_report_flat
        when "flat_with_strict"        then emit_report_flat_with_strict
        when "partitioned_with_strict" then emit_report_partitioned_with_strict
        else raise "unknown report_kind: #{kind}"
        end
