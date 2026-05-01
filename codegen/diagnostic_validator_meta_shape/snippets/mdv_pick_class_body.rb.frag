        rows = by_aggregate("RubyClass")
        name = self.class.target_class_name
        row = name ? rows.find { |r| r["attrs"]["name"] == name } : rows.first
        raise "no RubyClass row matching #{name.inspect}" unless row
        row
