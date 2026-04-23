        methods.each_with_index.map do |m, i|
          lead = (i == 0 && !blank_before_first) ? "" : "\n"
          lead + emit_method(m)
        end.join
