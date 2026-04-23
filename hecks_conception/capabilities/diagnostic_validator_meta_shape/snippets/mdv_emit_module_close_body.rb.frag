        path = klass["attrs"]["module_path"]
        depth = path.empty? ? 0 : path.split("::").length
        class_end = "  " * depth + "end\n"
        register = emit_register_line(klass, depth)
        module_ends = (0...depth).to_a.reverse.map { |i| "  " * i + "end\n" }.join
        class_end + register + module_ends
