        constants = by_aggregate("RubyConstant")
                      .select { |c| c["attrs"]["class_name"] == klass["attrs"]["name"] }
                      .sort_by { |c| c["attrs"]["order"].to_i }
        return "" if constants.empty?
        depth = klass["attrs"]["module_path"].empty? \
                  ? 0 : klass["attrs"]["module_path"].split("::").length
        indent = "  " * (depth + 1)
        lines = constants.map do |c|
          a = c["attrs"]
          "#{indent}#{a["name"]} = #{a["value_expr"]}\n"
        end.join
        klass["attrs"]["includes"].to_s.strip.empty? ? lines : "\n#{lines}"
