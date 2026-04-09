module Hecks
  module ValidationRules
    module Structure

    # Hecks::ValidationRules::Structure::ViewDomainTags
    #
    # Validates that domain tags in HTML and source files reference
    # real aggregates and commands from the bluebook. Scans for:
    #
    # - HTML: +data-domain="Aggregate.path"+ attributes
    # - JS/Ruby: +@domain Aggregate.Command+ annotations in doc headers
    #
    # Tags are split on dots: the first segment must be an aggregate name,
    # subsequent segments must be attributes or commands on that aggregate.
    #
    #   rule = ViewDomainTags.new(domain)
    #   rule.errors  # => ["actions.js: @domain references unknown aggregate 'Foo'"]
    #
    class ViewDomainTags < BaseRule
      def errors
        return [] unless source_dir
        result = []
        scan_files(source_dir).each do |path, tags|
          tags.each do |tag|
            err = validate_tag(tag, path)
            result << err if err
          end
        end
        result
      end

      private

      def source_dir
        return @source_dir if defined?(@source_dir)
        @source_dir = if @domain.respond_to?(:views_path) && @domain.views_path
          @domain.views_path
        elsif @domain.respond_to?(:source_path) && @domain.source_path
          find_views_dir(@domain.source_path)
        end
      end

      def find_views_dir(path)
        dir = File.dirname(path)
        # Walk up to find a directory containing views/ or assets/
        3.times do
          return dir if Dir.exist?(File.join(dir, "views")) || Dir.exist?(File.join(dir, "assets"))
          dir = File.dirname(dir)
        end
        File.dirname(path)
      end

      def scan_files(dir)
        results = {}
        Dir.glob(File.join(dir, "**/*.{html,js,rb}")).each do |path|
          tags = extract_tags(path)
          results[path] = tags unless tags.empty?
        end
        results
      end

      def extract_tags(path)
        content = File.read(path)
        tags = []
        # HTML: data-domain="Aggregate.path"
        content.scan(/data-domain="([^"]+)"/) { |m| tags << m[0] }
        # JS/Ruby: @domain Aggregate.Command (only in comments)
        content.scan(%r{(?://|#)\s*@domain\s+(.+)$}) do |m|
          m[0].split(",").each { |t| tags << t.strip }
        end
        tags.uniq
      end

      def validate_tag(tag, path)
        parts = tag.split(".")
        agg_name = parts.first
        aggregate = find_aggregate(agg_name)
        rel_path = path.sub(%r{.*/appeal/}, "")

        unless aggregate
          return error("#{rel_path}: references unknown aggregate '#{agg_name}'",
            hint: "Known aggregates: #{aggregate_names.join(', ')}")
        end

        return nil if parts.size < 2

        member = parts[1]
        unless known_member?(aggregate, member)
          return error("#{rel_path}: '#{agg_name}.#{member}' not found in #{agg_name}",
            hint: "Known members: #{member_names(aggregate).join(', ')}")
        end

        nil
      end

      def find_aggregate(name)
        @domain.aggregates.find { |a| a.name == name }
      end

      def aggregate_names
        @domain.aggregates.map(&:name)
      end

      def known_member?(aggregate, name)
        attrs = aggregate.attributes.map { |a| a.name.to_s }
        commands = aggregate.commands.map(&:name)
        value_objects = aggregate.respond_to?(:value_objects) ? aggregate.value_objects.map(&:name) : []
        tab_vals = tab_values(aggregate)

        all = attrs + commands + value_objects + tab_vals
        # Exact match
        return true if all.any? { |m| m.to_s == name || snake(m.to_s) == name }
        # Stem match: "sidebar" matches "sidebar_collapsed", "tab" matches "active_tab"
        attrs.any? { |a| a.start_with?(name) || a.end_with?(name) || a.include?(name) }
      end

      def member_names(aggregate)
        names = aggregate.attributes.map { |a| a.name.to_s }
        names += aggregate.commands.map(&:name)
        names += aggregate.value_objects.map(&:name) if aggregate.respond_to?(:value_objects)
        names
      end

      # Extract known values from TabName-style invariants
      def tab_values(aggregate)
        return [] unless aggregate.respond_to?(:value_objects)
        values = []
        aggregate.value_objects.each do |vo|
          next unless vo.respond_to?(:invariants)
          vo.invariants.each do |inv|
            source = inv.respond_to?(:source) ? inv.source : inv.to_s
            source.scan(/%w\[([^\]]+)\]/) { |m| values.concat(m[0].split) }
          end
        end
        values
      end

      def snake(str)
        str.gsub(/([A-Z])/, '_\1').sub(/^_/, "").downcase
      end
    end
    Hecks.register_validation_rule(ViewDomainTags)
    end
  end
end
