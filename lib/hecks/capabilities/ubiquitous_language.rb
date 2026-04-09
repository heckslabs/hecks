# Hecks::Capabilities::UbiquitousLanguage
#
# @domain Layout
#
# Everything data-domain tags give you, in one capability:
# - Accessibility: aria-label and aria-description from bluebook descriptions
# - Coverage: boot-time report of which UL concepts are missing from the app
# - Validation: ViewDomainTags rule checks tags match the UL
#
# The HTML only needs the minimal tag. The UL does the rest.
#
#   <nav data-domain="Layout.sidebar">
#
require_relative "dsl"
require_relative "product_executor/tag_scanner"

module Hecks
  module Capabilities
    module UbiquitousLanguage
      JS_PATH = File.expand_path("ubiquitous_language/ul_tagging.js", __dir__)

      # @param runtime [Hecks::Runtime]
      def self.apply(runtime)
        serve_js(runtime)
        report = run_coverage(runtime)

        runtime.instance_variable_set(:@ul_coverage, report) if report
        runtime.define_singleton_method(:ul_coverage) { @ul_coverage } if report
        puts "  \e[32m✓\e[0m ubiquitous_language"
      end

      def self.serve_js(runtime)
        return unless runtime.respond_to?(:static_assets_adapter)
        adapter = runtime.static_assets_adapter
        return unless adapter.respond_to?(:mount)
        js = File.read(JS_PATH)
        adapter.mount("/hecks/accessibility.js") do |_req, res|
          res["Content-Type"] = "application/javascript"
          res.body = js
        end
      end

      def self.run_coverage(runtime)
        domain = runtime.domain
        views_dir = find_views(domain, runtime)
        return unless views_dir

        tagged = ProductExecutor::TagScanner.scan(views_dir)
        tagged_aggs = tagged.keys.map { |t| t.split(".").first }.uniq
        ul_aggs = domain.aggregates.map(&:name)
        missing = ul_aggs - tagged_aggs
        covered = tagged_aggs.count { |a| ul_aggs.include?(a) }
        pct = ul_aggs.size > 0 ? (covered * 100.0 / ul_aggs.size).round : 0

        if missing.any?
          preview = missing.first(5).join(", ")
          puts "  \e[33m!\e[0m UL coverage: #{covered}/#{ul_aggs.size} (#{pct}%) — missing: #{preview}#{"..." if missing.size > 5}"
        else
          puts "  \e[32m✓\e[0m UL coverage: #{covered}/#{ul_aggs.size} (100%)"
        end

        { covered: covered, total: ul_aggs.size, missing: missing }
      end

      def self.find_views(domain, runtime)
        if domain.respond_to?(:source_path) && domain.source_path
          dir = File.dirname(domain.source_path)
          return dir if Dir.exist?(dir)
        end
        root = runtime.respond_to?(:root) ? runtime.root : nil
        root && Dir.exist?(root) ? root : nil
      end

      private_class_method :serve_js, :run_coverage, :find_views
    end
  end
end

Hecks.capability :ubiquitous_language do
  description "data-domain tags: accessibility, coverage reporting, and UL validation"
  direction :driven
  on_apply do |runtime|
    Hecks::Capabilities::UbiquitousLanguage.apply(runtime)
  end
end
