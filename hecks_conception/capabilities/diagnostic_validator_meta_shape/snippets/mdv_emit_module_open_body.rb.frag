        path = klass["attrs"]["module_path"]
        return "" if path.empty?
        segments = path.split("::")
        segments.each_with_index.map do |seg, i|
          "  " * i + "module #{seg}\n"
        end.join
