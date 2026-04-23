        raise "snippet missing: #{path}" unless File.exist?(path)
        lines = File.read(path).lines
        start = lines.find_index { |l| !l.strip.empty? && !l.strip.start_with?("//") }
        lines[start..].join
