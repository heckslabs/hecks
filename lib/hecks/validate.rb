# Hecks::Validate
#
# @domain AcceptanceTest
#
# Single source of truth for project health. Discovers projects, boots
# them, validates domain IR, checks UL tag coverage, and reports results.
# Used by the CLI, server boot, and CI.
#
#   result = Hecks::Validate.run("/path/to/project")
#   result[:errors]    # => []
#   result[:warnings]  # => ["UL coverage: 14/38 (37%)"]
#   result[:projects]  # => [{ name: "pizzas", aggregates: 2 }]
#
module Hecks
  module Validate
    def self.run(dir, format: "text")
      errors = []
      warnings = []
      projects = []

      paths = discover(dir)

      paths.each do |path|
        name = File.basename(path)
        begin
          result = Hecks.boot(path)
          runtimes = result.is_a?(Array) ? result : [result]
          agg_count = runtimes.sum { |rt| rt.domain.aggregates.size }

          # Domain validation
          runtimes.each do |rt|
            v = Validator.new(rt.domain)
            v.valid?
            v.errors.each { |e| warnings << "#{name}/#{rt.domain.name}: #{e}" }
            v.warnings.each { |w| warnings << "#{name}/#{rt.domain.name}: #{w}" } if v.respond_to?(:warnings)
          end

          # UL tag coverage
          runtimes.each do |rt|
            cov = ul_coverage(rt)
            warnings << "#{name}: UL coverage #{cov[:covered]}/#{cov[:total]} (#{cov[:pct]}%) — missing: #{cov[:missing].first(5).join(", ")}" if cov && cov[:missing].any?
          end

          projects << { name: name, aggregates: agg_count, status: :ok }
          print_project(name, agg_count, format)

        rescue ValidationError => e
          warnings << "#{name}: #{e.message.split("\n").first}"
          projects << { name: name, status: :warning, message: e.message.split("\n").first }
          print_warning(name, e.message.split("\n").first, format)
        rescue => e
          errors << "#{name}: #{e.message.split("\n").first}"
          projects << { name: name, status: :error, message: e.message.split("\n").first }
          print_error(name, e.message.split("\n").first, format)
        end
      end

      print_summary(projects, errors, warnings, format)

      { projects: projects, errors: errors, warnings: warnings }
    end

    def self.discover(dir)
      Dir.glob(File.join(dir, "**/hecks/*.bluebook"))
        .map { |f| File.dirname(File.dirname(f)) }
        .uniq.sort
    end

    def self.ul_coverage(runtime)
      domain = runtime.domain
      return nil unless domain.respond_to?(:source_path) && domain.source_path
      dir = File.dirname(domain.source_path)
      return nil unless Dir.exist?(dir)

      require "hecks/capabilities/product_executor/tag_scanner"
      tagged = Capabilities::ProductExecutor::TagScanner.scan(dir)
      tagged_aggs = tagged.keys.map { |t| t.split(".").first }.uniq
      ul_aggs = domain.aggregates.map(&:name)
      missing = ul_aggs - tagged_aggs
      covered = tagged_aggs.count { |a| ul_aggs.include?(a) }
      pct = ul_aggs.size > 0 ? (covered * 100.0 / ul_aggs.size).round : 0

      { covered: covered, total: ul_aggs.size, pct: pct, missing: missing }
    rescue
      nil
    end

    def self.print_project(name, agg_count, format)
      return if format == "json"
      puts "  \e[32m✓\e[0m #{name} (#{agg_count} aggregates)"
    end

    def self.print_warning(name, msg, format)
      return if format == "json"
      puts "  \e[33m!\e[0m #{name}: #{msg}"
    end

    def self.print_error(name, msg, format)
      return if format == "json"
      puts "  \e[31m✗\e[0m #{name}: #{msg}"
    end

    def self.print_summary(projects, errors, warnings, format)
      if format == "json"
        require "json"
        puts JSON.pretty_generate({ projects: projects, errors: errors, warnings: warnings })
        return
      end

      loaded = projects.count { |p| p[:status] == :ok }
      puts ""
      if warnings.any?
        puts "\e[33mWarnings (#{warnings.size}):\e[0m"
        warnings.first(10).each { |w| puts "  \e[33m!\e[0m #{w}" }
        puts "  \e[33m... and #{warnings.size - 10} more\e[0m" if warnings.size > 10
        puts ""
      end
      color = errors.any? ? "\e[31m" : "\e[32m"
      puts "#{color}#{loaded} loaded, #{errors.size} errors, #{warnings.size} warnings\e[0m"
    end

    private_class_method :discover, :ul_coverage, :print_project, :print_warning, :print_error, :print_summary
  end
end
