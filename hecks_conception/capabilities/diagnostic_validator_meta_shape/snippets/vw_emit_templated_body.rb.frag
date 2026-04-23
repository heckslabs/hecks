        case rule["attrs"]["check_kind"]
        when "count_threshold" then emit_count_threshold(rule)
        else raise "unknown templated check_kind: #{rule["attrs"]["check_kind"]}"
        end
