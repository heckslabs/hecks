        a = klass["attrs"]
        depth = a["module_path"].empty? ? 0 : a["module_path"].split("::").length
        indent = "  " * depth
        class_line = a["base_class"].empty? \
                       ? "#{indent}class #{a["name"]}\n"
                       : "#{indent}class #{a["name"]} < #{a["base_class"]}\n"
        mixins = a["includes"].split(",").map(&:strip).reject(&:empty?)
        mixin_lines = mixins.map { |m| "#{indent}  include #{m}\n" }.join
        class_line + mixin_lines
