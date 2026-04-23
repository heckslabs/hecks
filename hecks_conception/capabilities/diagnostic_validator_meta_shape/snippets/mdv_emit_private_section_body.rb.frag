        return "" if private_methods.empty?
        # Blank line, "private" (indented to method depth), blank line,
        # then each private method preceded by blank.
        indent = "      " # 3 levels of 2-space = 6 spaces (Hecks::Specializer::Class)
        "\n#{indent}private\n" + emit_methods(private_methods, blank_before_first: true)
