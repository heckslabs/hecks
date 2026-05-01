        case rule["attrs"]["body_strategy"]
        when "templated" then emit_templated(rule)
        when "embedded"  then emit_embedded(rule)
        else raise "unknown body_strategy: #{rule["attrs"]["body_strategy"]}"
        end
