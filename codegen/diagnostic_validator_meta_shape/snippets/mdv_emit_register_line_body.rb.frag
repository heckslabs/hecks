        name = klass["attrs"]["register_target_name"]
        return "" if name.nil? || name.empty?
        indent = "  " * depth
        "\n#{indent}register :#{name}, #{klass["attrs"]["name"]}\n"
