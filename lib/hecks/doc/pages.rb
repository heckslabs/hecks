require_relative "pages/catalogue"
require_relative "sources"

module Hecks
  module Doc
    # The documentation pages this checkout holds, declared through the Docs bluebook's own
    # commands into a Memory boot of it and read back with its `Page.Live` query, then each live
    # page's regions checked against their sources. The bluebook holds what a page is made of;
    # `Sources` answers whether a region still says what its source does.
    #
    # @example
    #   Hecks::Doc::Pages.drifts(root) # => [] when every live page matches its sources
    module Pages
      # The Docs domain's directory, booted standing alone in Memory.
      DOMAIN = File.expand_path("../docs", __dir__)

      module_function

      # @param root [String] the checkout
      # @return [Array<Hash>] every live page, as `{ path:, title:, regions: [{ anchor:, kind:,
      #   source:, assertion: }] }`, in path order
      def live(root)
        runtime = Hecks.boot(DOMAIN, environment: nil)
        Catalogue.new(root).pages.each { |page| declare(runtime, page) }
        runtime.query("Docs::Page.Live").map { |row| plain(row) }
      end

      # @param root [String] the checkout
      # @param doctest [#call, nil] runs one doctested page, answering true when its examples
      #   pass; nil leaves doctested regions to `spec/guides_spec.rb`
      # @return [Array<String>] each region that differs from its source, as `path#anchor: why`
      def drifts(root, doctest: nil)
        sources = Sources.new(root, doctest: doctest)
        live(root).flat_map do |page|
          page[:regions].filter_map { |region| sources.drift(page[:path], region) }
        end
      end

      # Declares one catalogued page and adds its regions, in reading order.
      #
      # @param runtime [Runtime::Dispatcher] the Memory boot of Docs
      # @param page [Catalogue::Entry] the page
      # @return [void]
      def declare(runtime, page)
        runtime.dispatch_flat("Docs::Page.Declare", path: { value: page.path }, title: { value: page.title },
                                                    standing: { value: "live" })
        page.regions.each { |region| runtime.dispatch_flat(*region.command(page.path)) }
      end

      # @param row [Hash] one `Page.Live` row
      # @return [Hash] the row's path, title and regions as plain Strings
      def plain(row)
        { path: row[:path].value, title: row[:title].value,
          regions: row[:regions].map { |region| region_fields(region) } }
      end

      # @param region [Runtime::Value] one `Region`
      # @return [Hash{Symbol => String}] its anchor, kind, source and assertion
      def region_fields(region)
        %i[anchor kind source assertion].to_h { |field| [field, region.public_send(field).fetch(:value)] }
      end
    end
  end
end
