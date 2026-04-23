        raw = klass["attrs"]["requires"].to_s
        return "" if raw.empty?
        paths = raw.split(",").map(&:strip).reject(&:empty?)
        return "" if paths.empty?
        paths.map { |p| "require_relative \"#{p}\"\n" }.join + "\n"
